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
        end

        #: (Executor::ExecutionScope, Hash[String, Array[Selection]], Set[DeferUsage]) -> void
        def register_deferred_scope(base_scope, field_selections, defer_usages)
          @works << DeferredWork.new(base_scope:, field_selections:, defer_usages:)
        end

        #: (Executor::ExecutionField[untyped], Array[untyped]) -> Array[untyped]
        def partition_stream(exec_field, resolved_objects)
          usage = exec_field.stream_usage
          return resolved_objects unless usage

          list_type = Util.unwrap_non_null(exec_field.type)
          return resolved_objects unless list_type.list?

          item_type = list_type.of_type
          partitioned = resolved_objects.each_with_index.map do |value, object_index|
            next value if value.nil? || value.is_a?(StandardError) || !value.is_a?(Array)

            initial_count = usage.initial_count
            next value if value.length <= initial_count

            path = exec_field.object_path(object_index)
            delivery = StreamDelivery.new(path, usage.label, parent: parent_delivery_for(path))
            work = StreamWork.new(
              parent_field: exec_field,
              delivery:,
              item_type:,
              remaining_items: value.drop(initial_count),
              initial_index: initial_count,
            )
            @works << work
            @work_by_delivery[delivery] = work
            value.take(initial_count)
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
          Result.new(initial_result:, subsequent_results: Enumerator.new { each_payload(_1) })
        end

        #: (DeferUsage, error_path) -> DeferredDelivery
        def delivery_for(defer_usage, path)
          existing = nearest_delivery_for(defer_usage, path)
          return existing if existing

          parent = if (parent_usage = defer_usage.parent)
            nearest_delivery_for(parent_usage, path)
          end

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
            break if ready.empty?

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

            pending = prepare_pending
            completed = completed_payloads(completed_deliveries, errors_by_delivery)
            payload = { "hasNext" => has_next? }
            payload["pending"] = @publisher.pending(pending) unless pending.empty?
            payload["incremental"] = incremental_payloads unless incremental_payloads.empty?
            payload["completed"] = completed unless completed.empty?
            yielder << payload
          end
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
            next if work.announced? || work.executed? || !work.ready?

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
          elsif !items.empty?
            incremental_payloads << @publisher.stream(work.delivery, items, errors:)
          end
          completed_deliveries << work.delivery
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
