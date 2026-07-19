# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class DeferredWork < Work
        #: Executor::ExecutionScope
        attr_reader :base_scope

        #: Hash[String, Array[Selection]]
        attr_reader :field_selections

        #: Set[DeferUsage]
        attr_reader :defer_usages

        #: (base_scope: Executor::ExecutionScope, field_selections: Hash[String, Array[Selection]], defer_usages: Set[DeferUsage]) -> void
        def initialize(base_scope:, field_selections:, defer_usages:)
          super()
          @base_scope = base_scope
          @field_selections = field_selections
          @defer_usages = defer_usages
          @entries = nil
          @deliveries_by_entry = {}.compare_by_identity
        end

        #: -> bool
        def ready?
          @base_scope.has_authorized_objects? && @base_scope.executed? && !@base_scope.aborted?
        end

        #: (Coordinator) -> Array[Entry]
        def entries(coordinator)
          @entries ||= begin
            entries = []
            index = 0
            while index < @base_scope.objects.length
              path = @base_scope.object_path(index)
              if coordinator.path_live?(path)
                entry = Entry.new(work: self, object: @base_scope.objects[index], path:, index:)
                @deliveries_by_entry[entry] = @defer_usages.map { coordinator.delivery_for(_1, path) }
                entries << entry
              end
              index += 1
            end
            entries.freeze
          end
        end

        #: (Entry) -> Array[DeferredDelivery]
        def deliveries_for(entry)
          @deliveries_by_entry.fetch(entry)
        end

        #: -> singleton(GraphQL::Schema::Object)
        def parent_type
          @base_scope.parent_type
        end

        #: -> Array[selection_node]
        def selections
          @field_selections.each_value.flat_map { _1.map(&:node) }.freeze
        end

        #: -> Array[String]
        def scope_path
          @base_scope.path
        end

        #: -> Array[String]
        def schema_path
          @base_scope.schema_path
        end

        #: -> Array[Executor::ExecutionDirective]
        def inherited_directives
          @base_scope.parent_field&.directives || EMPTY_ARRAY
        end
      end
    end
  end
end
