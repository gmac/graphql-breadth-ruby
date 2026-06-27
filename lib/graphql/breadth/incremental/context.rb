# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class Context
        #: Executor
        attr_reader :executor

        #: Publisher
        attr_reader :publisher

        #: (
        #|   Executor executor,
        #|   data: graphql_result,
        #| ) -> void
        def initialize(executor, data:)
          @executor = executor
          @data = data
          @publisher = Publisher.new
          @deferred_scopes = []
          @pending_deliveries = []
          @announced_deliveries = {}.compare_by_identity
          @completed_deliveries = {}.compare_by_identity
          @deliveries_by_usage = {}.compare_by_identity
        end

        #: (Executor::ExecutionScope, Hash[String, Array[Selection]], Set[DeferUsage]) -> void
        def register_deferred_scope(base_scope, field_selections, defer_usages)
          @deferred_scopes << DeferredExecutionScope.new(
            base_scope:,
            field_selections:,
            defer_usages:,
          )
        end

        #: -> bool
        def active?
          true
        end

        #: -> bool
        def deferred?
          @deferred_scopes.any?
        end

        #: -> bool
        def has_next?
          @deferred_scopes.any? { _1.announced? && !_1.executed? }
        end

        #: -> Array[DeferredDelivery]
        def prepare_pending
          @deferred_scopes.each do |deferred_scope|
            next if deferred_scope.announced? || !deferred_scope.ready?

            pending_deliveries_for(deferred_scope)
            deferred_scope.announced = true
          end

          @pending_deliveries.uniq!
          pending = @pending_deliveries
          @pending_deliveries = []
          pending
        end

        #: -> Array[DeferredExecutionScope]
        def ready_scopes
          @deferred_scopes.select { _1.announced? && !_1.executed? && _1.ready? }.each(&:prepare!)
        end

        #: (DeferredExecutionScope) -> Array[[Integer, error_path, Array[DeferredDelivery]]]
        def deliveries_for(deferred_scope)
          deliveries = []
          index = 0
          while index < deferred_scope.base_scope.objects.length
            path = deferred_scope.base_scope.object_path(index)
            unless deferred_path_nulled?(path)
              deferred_deliveries = deferred_scope.defer_usages.map { delivery_for(_1, path) }
              deliveries << [index, path, deferred_deliveries]
            end
            index += 1
          end
          deliveries
        end

        #: (Array[DeferredDelivery]) -> Array[graphql_result]
        def pending_payloads(deliveries)
          @publisher.pending(deliveries)
        end

        #: (Array[DeferredDelivery], error_path, graphql_result, ?errors: Array[error_hash]) -> graphql_result
        def incremental_payload(deliveries, path, data, errors: EMPTY_ARRAY)
          @publisher.incremental(deliveries, path, data, errors:)
        end

        #: (Array[DeferredDelivery], ?errors_by_delivery: Hash[DeferredDelivery, Array[error_hash]]) -> Array[graphql_result]
        def completed_payloads(deliveries, errors_by_delivery: EMPTY_OBJECT)
          deliveries.uniq.filter_map do |delivery|
            next if @completed_deliveries[delivery]
            next unless delivery_finished?(delivery)

            @completed_deliveries[delivery] = true
            @publisher.completed(delivery, errors: errors_by_delivery[delivery] || EMPTY_ARRAY)
          end
        end

        private

        #: (DeferredExecutionScope) -> Array[DeferredDelivery]
        def pending_deliveries_for(deferred_scope)
          pending = []
          index = 0
          while index < deferred_scope.base_scope.objects.length
            path = deferred_scope.base_scope.object_path(index)
            unless deferred_path_nulled?(path)
              deferred_scope.defer_usages.each do |defer_usage|
                delivery = delivery_for(defer_usage, path)
                unless @completed_deliveries[delivery] || @announced_deliveries[delivery]
                  @announced_deliveries[delivery] = true
                  pending << delivery
                  @pending_deliveries << delivery
                end
              end
            end
            index += 1
          end

          pending
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

        #: (DeferUsage, error_path) -> DeferredDelivery?
        def nearest_delivery_for(defer_usage, path)
          deliveries = @deliveries_by_usage[defer_usage]
          return nil unless deliveries

          deliveries
            .select { _1.path_prefix_of?(path) }
            .max_by { _1.path.length }
        end

        #: (DeferredDelivery) -> bool
        def delivery_finished?(delivery)
          defer_usage = defer_usage_for_delivery(delivery)
          return true unless defer_usage

          @deferred_scopes.none? { !_1.executed? && _1.defer_usages.include?(defer_usage) }
        end

        #: (DeferredDelivery) -> DeferUsage?
        def defer_usage_for_delivery(delivery)
          @deliveries_by_usage.each do |defer_usage, deliveries|
            return defer_usage if deliveries.include?(delivery)
          end

          nil
        end

        # True when the formatted initial result null-bubbled away the object at `path`
        # (e.g. a non-null child error nulled a nullable list element). Deferred execution rooted
        # at such a path must not be announced or delivered: there is no live object to patch.
        #: (error_path) -> bool
        def deferred_path_nulled?(path)
          return false if path.empty?

          path_nulled_in?(@data, path, 0)
        end

        # Walks `path` from `index` into the formatted result `value`, returning true once a
        # *present-but-nil* slot is reached. A missing Hash key or out-of-range Array index
        # returns false.
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
