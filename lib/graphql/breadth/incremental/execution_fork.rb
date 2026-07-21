# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class ExecutionFork < Executor
        #: Array[ExecutionScope]
        attr_reader :fork_scopes

        #: (Executor, Coordinator) -> void
        def initialize(host, coordinator)
          runtime = host.incremental_fork_runtime
          @provided_variables = runtime.provided_variables
          @schema = runtime.schema
          @resolvers = runtime.resolvers
          @query = runtime.query
          @context = runtime.context
          @input = runtime.input
          @authorization_class = runtime.authorization_class
          @authorization = @authorization_class.new
          @document = runtime.document
          @root_object = nil
          @context_value = runtime.context_value
          @tracers = runtime.tracers
          @result = nil
          @data = {}
          @errors = []
          @exec_queue = []
          @lazy_queue = []
          @invalidated_results = {}.compare_by_identity
          @abstract_result_types = nil
          @loader_cache = runtime.loader_cache
          @paths = nil
          @incremental = coordinator
          @executed = false
          @aborted = false
          @planner = ExecutionPlanner.new(executor: self, resolvers: @resolvers)
          @fork_scopes = []
          @scope_by_entry = {}.compare_by_identity
          @value_results = {}.compare_by_identity
        end

        #: (Array[Work], Coordinator) -> ExecutionFork
        def execute_works(works, coordinator)
          first = works.first #: as !nil
          entries = works.flat_map { _1.entries(coordinator) }
          field_selections = first.is_a?(DeferredWork) ? first.field_selections : nil
          defer_usages = first.is_a?(DeferredWork) ? first.defer_usages : EMPTY_SET

          if first.is_a?(StreamWork) && !first.parent_type.kind.composite?
            entries.each do |entry|
              @value_results[entry] = complete_value(first.item_type, entry.object, entry.path, first.parent_field)
            end
            return self
          end

          entries_by_type = if first.parent_type.kind.abstract?
            entries.group_by { resolved_type_for(first.parent_type, _1.object, first.parent_field) }
          else
            { first.parent_type => entries }
          end
          entries_by_type.each do |parent_type, typed_entries|
            scope = ExecutionScope.new(
              executor: self,
              parent_type:,
              selections: first.selections,
              entries: typed_entries,
              path: first.scope_path,
              schema_path: first.schema_path,
              inherited_directives: first.inherited_directives,
              incremental_field_selections: field_selections,
              defer_usages:,
            )
            typed_entries.each { @scope_by_entry[_1] = scope }
            @fork_scopes << scope
          end

          run!(@planner.plan_scopes(@fork_scopes)) unless entries.empty?
          self
        end

        #: (Entry) -> [graphql_result?, Array[error_hash]]
        def result_for(entry)
          return @value_results.fetch(entry) if @value_results.key?(entry)

          scope = @scope_by_entry.fetch(entry)
          result = scope.result_for(entry)
          error_result_formatter.format_object(scope.parent_type, scope.selections, result, entry.path)
        end

        private

        #: (singleton(GraphQL::Schema::Member), untyped, Executor::ExecutionField[untyped]) -> singleton(GraphQL::Schema::Object)
        def resolved_type_for(abstract_type, object, exec_field)
          type_resolver = @resolvers.dig(abstract_type.graphql_name, "__type__")
          object_type = if type_resolver
            type_resolver.call(object, @context)
          else
            resolved_type, resolved_object = @query.resolve_type(abstract_type, object)
            if resolved_type && @schema.lazy?(resolved_type)
              resolved_type, resolved_object = @schema.sync_lazy(resolved_type)
            end
            object = resolved_object unless object.equal?(resolved_object)
            resolved_type
          end

          possible_types = @context.types.possible_types(abstract_type)
          unless object_type && possible_types.include?(object_type)
            raise ImplementationError, "Failed to resolve a type for streamed #{abstract_type.graphql_name}"
          end

          object_type
        rescue StandardError => error
          raise handle_or_reraise(error, exec_field:)
        end

        #: (untyped, untyped, error_path, Executor::ExecutionField[untyped]) -> [untyped, Array[error_hash]]
        def complete_value(type, value, path, exec_field)
          if value.nil? || value.is_a?(StandardError)
            return missing_value(type, value, path, exec_field)
          end

          if type.list?
            unless value.is_a?(Array)
              raise InvalidListResultError.new(exec_field:, result_type: value.class)
            end

            item_type = Util.unwrap_non_null(type).of_type
            completed = []
            errors = []
            value.each_with_index do |item, index|
              result, item_errors = complete_value(item_type, item, [*path, index], exec_field)
              completed << result
              errors.concat(item_errors)
            end
            return [completed, errors]
          end

          coerced = type.unwrap.coerce_result(value, @context)
          return missing_value(type, nil, path, exec_field) if coerced.nil?

          [coerced, EMPTY_ARRAY]
        rescue StandardError => error
          missing_value(type, error, path, exec_field)
        end

        #: (untyped, StandardError?, error_path, Executor::ExecutionField[untyped]) -> [untyped, Array[error_hash]]
        def missing_value(type, error, path, exec_field)
          error ||= InvalidNullError.new(exec_field:, list_item: true) if type.non_null?
          return [nil, EMPTY_ARRAY] unless error

          handled = handle_or_reraise(error, exec_field:)
          errors = []
          handled.each do |entry|
            next if entry.equal?(UNREPORTED_ERROR)

            errors << entry.to_h.tap { _1["path"] = path }
            @context.errors << entry.cause if entry.cause
          end
          [nil, errors]
        end
      end
    end
  end
end
