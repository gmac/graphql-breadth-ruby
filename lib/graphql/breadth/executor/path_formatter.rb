# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    class Executor
      #  Builds paths to specific breadth object positions as exact object paths, ex:
      #  - Scope path (namespace): ["products", "variants"]
      #  - Object path (exact path): ["products", 0, "variants", 1]
      #  Object pathing assembles breadth indices for all scopes ascending from the targeted scope, ex:
      #  {
      #    <TargetExecScope> => {
      #      0 => [0, 1, 1, 2], # << zero index always maps objects in this scope to objects in the parent scope
      #      1 => [0, 0, 1, 0], # << maps a first-order list in this scope
      #      2 => [ ... ], # << maps a second-order list in this scope, etc...
      #    },
      #    <ParentExecScope> => { ... },
      #  }
      #  All numeric indexing arrays have size matching the number of objects in their scope.
      #  To read an object path, we follow the Nth position of each scope's index map ascending up the scope tree.
      #  Building these indices adds execution overhead that isn't needed regularly, so this is only done as part of deferred work.
      class PathFormatter
        #: Hash[Executor::ExecutionScope, Hash[Integer, Array[Integer]]]
        attr_reader :indices_by_scope

        def initialize
          @indices_by_scope = Hash.new { |h1, exec_scope| h1[exec_scope] = Hash.new { |h2, index| h2[index] = [] } }.compare_by_identity
        end

        #: (Executor::ExecutionScope, Integer) -> error_path
        def object_path(exec_scope, index)
          current_path = []

          current_scope = exec_scope #: Executor::ExecutionScope?
          breadth_index = index
          while current_scope
            if current_scope.is_a?(Incremental::ExecutionScope)
              return [*current_scope.object_path(breadth_index), *current_path]
            end

            # index the scope unless it has already been done
            scope_indices = @indices_by_scope[current_scope]
            index_scope(current_scope, scope_indices) if scope_indices.empty?

            # loop backward through all the scope's indices...
            # - all scopes have at least one index that defines the parent scope position
            # - list scopes have additional indices for each layer of list wrapping
            i = scope_indices.length - 1
            while i >= 0
              if i.zero?
                # at the lowest index, recalibrate for the next highest scope
                breadth_index = scope_indices[i][breadth_index] #: as Integer
              else
                # higher indices add list positions to the current path
                current_path.prepend(scope_indices[i][breadth_index])
              end
              i -= 1
            end

            # before going up a scope, add the parent field key into current path
            key = current_scope.parent_field&.key
            current_path.prepend(key) if key
            current_scope = current_scope.parent
          end

          current_path
        end

        private

        #: (Executor::ExecutionScope, Hash[Integer, Array[Integer]]) -> void
        def index_scope(exec_scope, scope_indices)
          raise ArgumentError, "Scope must not be indexed" unless scope_indices.empty?
          raise ArgumentError, "Scope must be executed" unless exec_scope.executed?

          parent_objects = exec_scope.objects
          current_type = exec_scope.parent_type
          if (parent_field = exec_scope.parent_field)
            parent_objects = parent_field.result #: as !nil
            current_type = parent_field.type
          end

          object_path = []
          i = 0
          while i < parent_objects.length
            object_path[0] = i
            build_indices(current_type, parent_objects[i], object_path, scope_indices)
            i += 1
          end

          scope_indices.each(&:freeze)
          scope_indices.freeze
        end

        #: (singleton(GraphQL::Schema::Member), untyped, Array[Integer], Hash[Integer, Array[Integer]]) -> void
        def build_indices(current_type, object, object_path, next_indices)
          return if object.nil? || object.is_a?(ExecutionError)

          if current_type.list?
            raise ImplementationError, "Expected Array, got #{object.class}" unless object.is_a?(Array)

            current_type = Util.unwrap_non_null(current_type)

            i = 0
            while i < object.length
              object_path << i
              build_indices(current_type.of_type, object[i], object_path, next_indices)
              object_path.pop
              i += 1
            end
          else
            i = 0
            while i < object_path.length
              next_index = object_path[i] #: as !nil
              next_map = next_indices[i] #: as !nil
              next_map << next_index
              i += 1
            end
          end
        end
      end
    end
  end
end
