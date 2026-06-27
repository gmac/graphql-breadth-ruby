# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    class Executor
      class ExecutionScope
        include LazyElement
        include HasAttributes

        #: Executor
        attr_reader :executor

        #: singleton(GraphQL::Schema::Object)
        attr_reader :parent_type

        #: ExecutionField[untyped]?
        attr_reader :parent_field

        #: Array[selection_node]
        attr_reader :selections

        #: Array[untyped]
        attr_reader :objects

        #: Array[untyped]
        attr_reader :results

        #: AbstractExecutionScope?
        attr_reader :abstraction

        #: Array[String]
        attr_reader :path

        #: ExecutionScope?
        attr_reader :parent

        #: Hash[String, ExecutionField[untyped]]
        attr_reader :fields

        #: bool
        attr_writer :executed

        #: (
        #|   executor: Executor,
        #|   parent_type: singleton(GraphQL::Schema::Object),
        #|   selections: Array[selection_node],
        #|   objects: Array[untyped],
        #|   results: Array[untyped],
        #|   ?abstraction: AbstractExecutionScope?,
        #|   ?parent_field: ExecutionField[untyped]?,
        #|   ?path: Array[String],
        #|   ?parent: ExecutionScope?,
        #|   ?deferred: bool,
        #| ) -> void
        def initialize(
          executor:,
          parent_type:,
          selections:,
          objects:,
          results:,
          abstraction: nil,
          parent_field: nil,
          path: [],
          parent: nil,
          deferred: false
        )
          super()
          @executor = executor
          @parent_type = parent_type
          @parent_field = parent_field
          @selections = selections
          @objects = objects
          @results = results
          @abstraction = abstraction
          @path = (parent_field ? parent_field.path : path).freeze
          @parent = parent_field ? parent_field.scope : parent
          @fields = {}
          @deferred = deferred
          @executed = false
          @root = nil
          @planning_root = nil
          @aborted = false
        end

        #: -> GraphQL::Query::Context
        def context
          @executor.context
        end

        #: -> ExecutionScope
        def root
          @root ||= @parent ? @parent.root : self
        end

        #: -> ExecutionScope
        def planning_root
          @planning_root ||= (abstraction || @parent.nil?) ? self : @parent.planning_root
        end

        #: -> Integer
        def depth
          @path.length
        end

        #: -> Array[String]
        def schema_path
          if (field = parent_field)
            field.schema_path
          else
            EMPTY_ARRAY
          end
        end

        #: (Integer) -> error_path
        def object_path(index)
          @executor.paths.object_path(self, index)
        end

        #: -> bool
        def executed?
          @executed
        end

        #: -> bool
        def abort!
          @aborted = true
        end

        #: -> bool
        def aborted?
          @aborted
        end

        #: -> bool
        def deferred?
          @deferred
        end

        #: -> ExecutionScope?
        def deferred_root
          return self if deferred?

          exec_scope = @parent
          while exec_scope
            return exec_scope if exec_scope.deferred?

            exec_scope = exec_scope.parent
          end

          nil
        end

        #: -> bool
        def aborted_subtree?
          return true if @aborted

          exec_field = parent_field #: ExecutionField[untyped]?
          while exec_field
            if exec_field.scope.aborted?
              return abort!
            end
            exec_field = exec_field.scope.parent_field
          end
          false
        end

        #: -> bool
        def has_authorized_objects?
          @objects.frozen? && !@objects.empty?
        end

        #: -> String
        def inspect
          "#<ExecutionScope: [#{path.join(", ")}]>"
        end
      end
    end
  end
end
