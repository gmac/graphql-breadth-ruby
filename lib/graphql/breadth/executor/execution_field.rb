# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    class Executor
      class ExecutionField
        include LazyElement
        include HasAttributes

        LAZY_STATE_EXECUTING = :executing

        # Field's name as it appears in the response.
        #: String
        attr_reader :key

        # Field's name according to schema.
        #: String
        attr_reader :name

        #: GraphQL::Schema::Field?
        attr_reader :definition

        #: Array[ExecutionDirective]
        attr_reader :directives

        #: FieldResolver
        attr_reader :resolver

        #: Array[GraphQL::Language::Nodes::Field]
        attr_reader :nodes

        # Only populated during incremental (`@defer`) execution; nil on the hot path.
        #: Array[Incremental::Selection]?
        attr_reader :incremental_selections

        #: Incremental::StreamUsage?
        attr_reader :stream_usage

        #: graphql_arguments
        attr_reader :arguments

        #: ExecutionScope
        attr_accessor :scope

        #: singleton(GraphQL::Schema::Member)
        attr_accessor :type

        #: untyped
        attr_accessor :result

        #: (
        #|   String,
        #|   nodes: Array[GraphQL::Language::Nodes::Field],
        #|   scope: ExecutionScope,
        #|   definition: GraphQL::Schema::Field,
        #|   resolver: FieldResolver,
        #|   ?directives: Array[ExecutionDirective],
        #|   ?incremental_selections: Array[Incremental::Selection]?,
        #|   ?stream_usage: Incremental::StreamUsage?,
        #| ) -> void
        def initialize(key, nodes:, scope:, definition:, resolver:, directives: EMPTY_ARRAY, incremental_selections: nil, stream_usage: nil)
          super()
          @key = key.freeze
          @scope = scope
          @definition = definition
          @directives = directives.freeze
          @resolver = resolver
          @name = definition.graphql_name.freeze
          @nodes = nodes.freeze
          @type = definition.type
          @result = nil
          @arguments, @argument_errors = executor.input.coerce_argument_values(@definition, @nodes.first)
          @mutable_arguments = nil
          @incremental_selections = incremental_selections
          @stream_usage = stream_usage if stream_usage
          @path = nil
          @schema_path = nil
        end

        #: () -> Array[ObjectType]
        def objects
          @scope.objects
        end

        #: () -> GraphQL::Query::Context
        def context
          @scope.context
        end

        #: () -> singleton(GraphQL::Schema::Member)
        def parent_type
          @scope.parent_type
        end

        #: () -> Executor
        def executor
          @scope.executor
        end

        #: () -> ExecutionScope
        def root
          @scope.root
        end

        #: () -> ExecutionScope
        def planning_root
          @scope.planning_root
        end

        #: -> Integer
        def depth
          path.length
        end

        #: () -> Array[String]
        def schema_path
          @schema_path ||= [*@scope.schema_path, name].freeze
        end

        #: (
        #|   loader_class: singleton(LazyLoader),
        #|   keys: Array[untyped],
        #|   ?args: loader_args?,
        #|   ?eager_values: Hash[untyped, untyped]?,
        #|   ?load_nil_keys: bool,
        #| ) -> ExecutionPromise
        def lazy(loader_class:, keys:, args: nil, eager_values: nil, load_nil_keys: false)
          unless allows_lazy?
            raise LazySequencingError.new(lazy_element: self, method_name: "lazy")
          end

          executor.lazy_loader_for(loader_class, args).load(
            element: self,
            keys: keys,
            eager_values: eager_values,
            load_nil_keys: load_nil_keys,
          )
        end

        #: (Array[ExecutionPromise]) -> ExecutionPromise
        def await_all(promises)
          super
        end

        #: () -> bool
        def allows_lazy?
          @lazy_state == LAZY_STATE_EXECUTING
        end

        #: () -> Array[String]
        def path
          @path ||= [*@scope.path, @key].freeze
        end

        #: (Integer) -> error_path
        def object_path(index)
          path = @scope.object_path(index)
          path << @key
          path
        end

        #: [T] () { (untyped) -> (T | ExecutionError) } -> Array[T | ExecutionError]
        def map_objects(&block)
          objects.map do |obj|
            yield(obj)
          rescue StandardError => e
            handle_or_reraise(e)
          end
        end

        #: [T] () { (untyped, Integer) -> (T | ExecutionError) } -> Array[T | ExecutionError]
        def map_objects_with_index(&block)
          objects.map.with_index do |obj, index|
            yield(obj, index)
          rescue StandardError => e
            handle_or_reraise(e)
          end
        end

        #: [T] (T) -> Array[T]
        def resolve_all(value)
          value = case value
          when StandardError
            handle_or_reraise(value)
          else
            value
          end
          Array.new(objects.length, value)
        end

        #: (Exception) -> ExecutionError
        def handle_or_reraise(error)
          executor.handle_or_reraise(error, exec_field: self)
        end

        #: () -> Array[selection_node]
        def selections
          if @nodes.length > 1
            @nodes.flat_map(&:selections)
          else
            @nodes.first.selections
          end
        end

        #: () -> graphql_arguments
        def mutable_arguments
          @mutable_arguments ||= Util.deep_copy(arguments)
        end

        #: () -> void
        def validate!
          unless @argument_errors.empty?
            node = @nodes.first
            @argument_errors.each { _1.add_parent_node(node) }
            raise ExecutionErrorSet.new(exec_field: self, errors: @argument_errors)
          end
        end

        #: () -> bool
        def lazy_result?
          @result.is_a?(ExecutionPromise)
        end

        #: () -> bool
        def has_result?
          !@result.nil?
        end

        #: () -> bool
        def propagates_null?
          current_type = @type
          return false unless current_type.kind.wraps?

          while current_type.list?
            return false unless current_type.non_null?

            current_type = Util.unwrap_non_null(current_type).of_type
          end

          current_type.non_null?
        end

        #: () -> String
        def inspect
          alias_prefix = key == name ? "" : "#{key} => "
          "#<ExecutionField: #{alias_prefix}#{scope.parent_type.graphql_name}.#{name}>"
        end

        def lazy_state_executing!
          raise LazyStateTransitionError.new(@lazy_state, LAZY_STATE_EXECUTING) unless @lazy_state == LAZY_STATE_PRELOADING

          @lazy_state = LAZY_STATE_EXECUTING
        end

        private

        #: () -> bool
        def lazy_state_lockable?
          @lazy_state == LAZY_STATE_PRELOADING || @lazy_state == LAZY_STATE_EXECUTING
        end
      end
    end
  end
end
