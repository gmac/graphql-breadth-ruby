# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class ExecutionScope < Executor::ExecutionScope
        #: Array[Entry]
        attr_reader :entries

        #: Hash[String, Array[Selection]]?
        attr_reader :incremental_field_selections

        #: Set[DeferUsage]
        attr_reader :defer_usages

        #: Array[Executor::ExecutionDirective]
        attr_reader :inherited_directives

        #: (
        #|   executor: Executor,
        #|   parent_type: singleton(GraphQL::Schema::Object),
        #|   selections: Array[selection_node],
        #|   entries: Array[Entry],
        #|   path: Array[String],
        #|   schema_path: Array[String],
        #|   inherited_directives: Array[Executor::ExecutionDirective],
        #|   ?incremental_field_selections: Hash[String, Array[Selection]]?,
        #|   ?defer_usages: Set[DeferUsage],
        #| ) -> void
        def initialize(
          executor:,
          parent_type:,
          selections:,
          entries:,
          path:,
          schema_path:,
          inherited_directives:,
          incremental_field_selections: nil,
          defer_usages: EMPTY_SET
        )
          @entries = entries.dup
          @object_paths = entries.map(&:path)
          @results_by_entry = {}.compare_by_identity
          results = entries.map do |entry|
            result = {}
            @results_by_entry[entry] = result
            result
          end
          @schema_path = schema_path.freeze
          @inherited_directives = inherited_directives
          @incremental_field_selections = incremental_field_selections
          @defer_usages = defer_usages

          super(
            executor:,
            parent_type:,
            selections:,
            objects: entries.map(&:object),
            results:,
            path:,
            deferred: true,
          )
        end

        #: (Integer) -> error_path
        def object_path(index)
          @object_paths.fetch(index).dup
        end

        #: -> Array[String]
        def schema_path
          @schema_path
        end

        #: (Entry) -> graphql_result
        def result_for(entry)
          @results_by_entry.fetch(entry)
        end

        #: (Integer) -> void
        def remove_entry_at(index)
          @entries.delete_at(index)
          @object_paths.delete_at(index)
        end

        #: -> void
        def freeze_entry_paths!
          @entries.freeze
          @object_paths.each(&:freeze)
          @object_paths.freeze
        end
      end
    end
  end
end
