# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class Coordinator
        #: Executor
        attr_reader :executor

        #: Publisher
        attr_reader :publisher

        #: (Executor, data: graphql_result) -> void
        def initialize(executor, data:)
          @executor = executor
          @data = data
          @publisher = Publisher.new
          @works = []
          @announced_deliveries = {}.compare_by_identity
          @completed_deliveries = {}.compare_by_identity
          @failed_deliveries = {}.compare_by_identity
          @deliveries_by_usage = {}.compare_by_identity
          @work_by_delivery = {}.compare_by_identity
          @stream_sessions = []
          @stream_works_by_session = {}.compare_by_identity
          @stream_completion_errors = {}.compare_by_identity
        end

        #: (Executor::ExecutionScope, Hash[String, Array[Selection]], Set[DeferUsage]) -> void
        def register_deferred_scope(base_scope, field_selections, defer_usages)
          @works << DeferredWork.new(base_scope:, field_selections:, defer_usages:)
        end

        #: (Executor::ExecutionField[untyped], Array[untyped] | Stream::Session) -> Array[untyped]
        def partition_stream(exec_field, resolved_objects)
          usage = exec_field.stream_usage
          return resolved_objects unless usage

          list_type = Util.unwrap_non_null(exec_field.type)
          return resolved_objects unless list_type.list?

          session = if resolved_objects.is_a?(Stream::Session)
            resolved_objects
          else
            Stream.eager(resolved_objects)
          end
          session.bind(exec_field.objects.length)
          partitioned = session.initial_items(usage.initial_count, @executor)
          works = {}
          item_type = list_type.of_type
          session.pending_positions.each do |object_index|
            path = exec_field.object_path(object_index)
            delivery = StreamDelivery.new(path, usage.label, parent: parent_delivery_for(path))
            work = StreamWork.new(
              parent_field: exec_field,
              delivery:,
              item_type:,
              session:,
              position: object_index,
              initial_index: partitioned[object_index].is_a?(Array) ? partitioned[object_index].length : 0,
            )
            @works << work
            @work_by_delivery[delivery] = work
            works[object_index] = work
          end

          if works.empty?
            session.close
          else
            @stream_sessions << session
            @stream_works_by_session[session] = works
          end

          exec_field.result = partitioned
          partitioned
        end

        #: (graphql_result) -> Result
        def result(initial_result)
          pending = prepare_pending
          return Result.new(initial_result:, subsequent_results: EMPTY_ARRAY) if pending.empty?

          initial_result["pending"] = @publisher.pending(pending)
          initial_result["hasNext"] = true
          payloads = Enumerator.new { each_payload(_1) }
          Result.new(
            initial_result:,
            subsequent_results: Stream::EnumeratorCursor.new(payloads, blocking: true),
          )
        end

        #: (DeferUsage, error_path) -> DeferredDelivery
        def delivery_for(defer_usage, path)
          existing = nearest_delivery_for(defer_usage, path)
          return existing if existing

          parent = if (parent_usage = defer_usage.parent)
            nearest_delivery_for(parent_usage, path)
          end
          parent ||= parent_delivery_for(path)

          delivery = DeferredDelivery.new(path.dup, defer_usage.label, parent:)
          (@deliveries_by_usage[defer_usage] ||= []) << delivery
          delivery
        end

        #: (error_path) -> bool
        def path_live?(path)
          !path_nulled_in?(@data, path, 0)
        end

        private

        #: (Enumerator::Yielder) -> void
        def each_payload(yielder)
          loop do
            ready = ready_cohort
            unless ready.any?
              pull_stream_batches
              ready = ready_cohort
            end

            if ready.empty?
              pending = prepare_pending
              completed_deliveries = completed_stream_deliveries
              completed = completed_payloads(completed_deliveries, @stream_completion_errors)
              break if pending.empty? && completed.empty?

              payload = { "hasNext" => has_next? }
              payload["pending"] = @publisher.pending(pending) unless pending.empty?
              payload["completed"] = completed unless completed.empty?
              yielder << payload
              next
            end

            fork = ExecutionFork.new(@executor, self).execute_works(ready, self)
            incremental_payloads = []
            completed_deliveries = []
            errors_by_delivery = {}.compare_by_identity

            ready.each do |work|
              if work.is_a?(DeferredWork)
                collect_deferred_outcome(work, fork, incremental_payloads, completed_deliveries, errors_by_delivery)
              else
                collect_stream_outcome(work, fork, incremental_payloads, completed_deliveries, errors_by_delivery)
              end
            end

            completed_deliveries.concat(completed_stream_deliveries)
            @stream_completion_errors.each do |delivery, errors|
              errors_by_delivery[delivery] ||= errors
            end
            pending = prepare_pending
            completed = completed_payloads(completed_deliveries, errors_by_delivery)
            payload = { "hasNext" => has_next? }
            payload["pending"] = @publisher.pending(pending) unless pending.empty?
            payload["incremental"] = incremental_payloads unless incremental_payloads.empty?
            payload["completed"] = completed unless completed.empty?
            yielder << payload
          end
        ensure
          @stream_sessions.each(&:close)
        end

        #: -> Array[Work]
        def ready_cohort
          first = @works.find { _1.announced? && !_1.executed? && _1.ready? }
          return EMPTY_ARRAY unless first

          key = first.cohort_key
          @works.select { _1.announced? && !_1.executed? && _1.ready? && _1.cohort_key == key }
        end

        #: -> Array[Delivery]
        def prepare_pending
          pending = []
          @works.each do |work|
            next if work.announced? || work.executed? || !work.announceable?

            deliveries = if work.is_a?(DeferredWork)
              work.entries(self).flat_map { work.deliveries_for(_1) }
            elsif path_live?(work.delivery.path)
              [work.delivery]
            else
              EMPTY_ARRAY
            end

            deliveries.reject! { parent_failed?(_1) || @completed_deliveries[_1] }
            if deliveries.empty?
              work.cancel!
              work.session.close_position(work.position) if work.is_a?(StreamWork)
              next
            end

            work.announce!
            deliveries.each do |delivery|
              next if @announced_deliveries[delivery]

              @announced_deliveries[delivery] = true
              @work_by_delivery[delivery] ||= work
              pending << delivery
            end
          end
          pending.uniq
        end

        #: (DeferredWork, ExecutionFork, Array[graphql_result], Array[Delivery], Hash[Delivery, Array[error_hash]]) -> void
        def collect_deferred_outcome(work, fork, incremental_payloads, completed_deliveries, errors_by_delivery)
          work.entries(self).each do |entry|
            deliveries = work.deliveries_for(entry)
            data, errors = fork.result_for(entry)
            if data.nil? && !errors.empty?
              deliveries.each do |delivery|
                (errors_by_delivery[delivery] ||= []).concat(errors)
                @failed_deliveries[delivery] = true
              end
            else
              incremental_payloads << @publisher.deferred(deliveries, entry.path, data, errors:)
            end
            completed_deliveries.concat(deliveries)
          end
          work.finish!
        end

        #: (StreamWork, ExecutionFork, Array[graphql_result], Array[Delivery], Hash[Delivery, Array[error_hash]]) -> void
        def collect_stream_outcome(work, fork, incremental_payloads, completed_deliveries, errors_by_delivery)
          items = []
          errors = []
          failed = false

          work.entries(self).each do |entry|
            data, item_errors = fork.result_for(entry)
            if data.nil? && !item_errors.empty? && work.item_type.non_null?
              errors.concat(item_errors)
              failed = true
              break
            end

            items << data
            errors.concat(item_errors)
          end

          if failed
            errors_by_delivery[work.delivery] = errors
            @failed_deliveries[work.delivery] = true
            work.fail!(ExecutionError.new("Stream terminated after a non-null item error"))
            work.session.close_position(work.position)
          elsif !items.empty?
            incremental_payloads << @publisher.stream(work.delivery, items, errors:)
          end

          work.finish_batch! unless failed
          completed_deliveries << work.delivery if work.executed?
        end

        #: -> bool
        def pull_stream_batches
          progressed = false

          @stream_sessions.each do |session|
            works = @stream_works_by_session.fetch(session)
            active = works.values.select { _1.announced? && !_1.executed? }
            next if active.empty? || active.any?(&:batch_pending?)

            batch = session.next_batch(@executor)
            next if batch.empty?

            progressed = true
            completed = batch.completed_positions.to_set
            positions = batch.items_by_position.keys | batch.completed_positions | batch.errors_by_position.keys
            positions.each do |position|
              work = works[position]
              next unless work && work.announced? && !work.executed?

              if (error = batch.errors_by_position[position])
                work.fail!(error)
                @failed_deliveries[work.delivery] = true
                @stream_completion_errors[work.delivery] = format_stream_source_error(work, error)
              elsif (items = batch.items_by_position[position]) && !items.empty?
                work.load_batch(items, complete: completed.include?(position))
              elsif completed.include?(position)
                work.complete!
              end
            end
          end

          progressed
        end

        #: -> Array[StreamDelivery]
        def completed_stream_deliveries
          @works.filter_map do |work|
            next unless work.is_a?(StreamWork) && work.announced? && work.executed?
            next if @completed_deliveries[work.delivery]

            work.delivery
          end
        end

        #: (StreamWork, StandardError) -> Array[error_hash]
        def format_stream_source_error(work, error)
          errors = []
          @executor.handle_or_reraise(error, exec_field: work.parent_field).each do |entry|
            next if entry.equal?(UNREPORTED_ERROR)

            errors << entry.to_h.tap { _1["path"] ||= work.delivery.path }
          end
          errors
        end

        #: (Array[Delivery], Hash[Delivery, Array[error_hash]]) -> Array[graphql_result]
        def completed_payloads(deliveries, errors_by_delivery)
          deliveries.uniq.filter_map do |delivery|
            next if @completed_deliveries[delivery]
            next unless delivery_finished?(delivery)

            @completed_deliveries[delivery] = true
            @publisher.completed(delivery, errors: errors_by_delivery[delivery] || EMPTY_ARRAY)
          end
        end

        #: (Delivery) -> bool
        def delivery_finished?(delivery)
          if delivery.is_a?(StreamDelivery)
            work = @work_by_delivery[delivery]
            return !work || work.executed?
          end

          usage = defer_usage_for_delivery(delivery)
          return true unless usage

          @works.none? { _1.is_a?(DeferredWork) && !_1.executed? && _1.defer_usages.include?(usage) }
        end

        #: -> bool
        def has_next?
          @works.any? { _1.announced? && !_1.executed? }
        end

        #: (Delivery) -> bool
        def parent_failed?(delivery)
          parent = delivery.parent
          parent && (@failed_deliveries[parent] || @completed_deliveries[parent] && parent_failed?(parent))
        end

        #: (error_path) -> Delivery?
        def parent_delivery_for(path)
          deliveries = @announced_deliveries.keys.select { _1.path_prefix_of?(path) }
          deliveries.max_by { _1.path.length }
        end

        #: (DeferUsage, error_path) -> DeferredDelivery?
        def nearest_delivery_for(defer_usage, path)
          deliveries = @deliveries_by_usage[defer_usage]
          return nil unless deliveries

          deliveries.select { _1.path_prefix_of?(path) }.max_by { _1.path.length }
        end

        #: (DeferredDelivery) -> DeferUsage?
        def defer_usage_for_delivery(delivery)
          @deliveries_by_usage.each do |usage, deliveries|
            return usage if deliveries.include?(delivery)
          end
          nil
        end

        #: (untyped, error_path, Integer) -> bool
        def path_nulled_in?(value, path, index)
          return false if index == path.length

          segment = path[index]
          child = case value
          when Hash
            return false unless value.key?(segment)
            value[segment]
          when Array
            return false unless segment.is_a?(Integer) && segment >= 0 && segment < value.length
            value[segment]
          else
            return false
          end

          return true if child.nil?

          path_nulled_in?(child, path, index + 1)
        end
      end
    end
  end
end
