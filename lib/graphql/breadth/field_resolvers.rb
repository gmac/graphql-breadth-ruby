# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    class FieldResolver
      #: (Executor::ExecutionField[untyped], GraphQL::Query::Context) -> void
      def plan(_exec_field, _ctx)
        nil
      end

      #: (Executor::ExecutionField[untyped], GraphQL::Query::Context) -> (Array[untyped] | Executor::ExecutionPromise)
      def resolve(exec_field, ctx)
        raise NotImplementedError, "FieldResolver#resolve must be implemented."
      end

      #: (
      #|   Executor::ExecutionField[untyped],
      #|   GraphQL::Query::Context,
      #|   initial_count: Integer,
      #| ) -> (Incremental::Stream::Session | Enumerator | Array[Enumerator?] | Executor::ExecutionPromise)?
      def stream(_exec_field, _ctx, initial_count:)
        nil
      end

      #: (Array[untyped] | Executor::ExecutionPromise) { (Array[untyped]) -> Array[untyped] } -> (Array[untyped] | Executor::ExecutionPromise)
      def handle_resolved(result, &block)
        if result.is_a?(Executor::ExecutionPromise)
          result.then { |values| block.call(values) }
        else
          block.call(result)
        end
      end

      #: (Executor::ExecutionField[untyped], GraphQL::Query::Context) -> Enumerable
      def subscribe(_exec_field, _ctx)
        raise NotImplementedError, "FieldResolver#subscribe must be implemented."
      end
    end

    class HashKeyResolver < FieldResolver
      #: String | Symbol
      attr_reader :key

      #: (String | Symbol) -> void
      def initialize(key)
        @key = key
      end

      #: (Executor::ExecutionField[untyped], GraphQL::Query::Context) -> Array[untyped]
      def resolve(exec_field, _ctx)
        exec_field.map_objects { _1[@key] }
      end
    end

    class MethodResolver < FieldResolver
      #: type method_name = String | Symbol

      #: (*method_name, ?fallback: untyped) -> void
      def initialize(*names, fallback: nil)
        @names = names
        @fallback = fallback
      end

      #: (Executor::ExecutionField[untyped], GraphQL::Query::Context) -> Array[untyped]
      def resolve(exec_field, _ctx)
        exec_field.map_objects do |obj|
          @names.reduce(obj) do |memo, name|
            break @fallback if memo.nil? && !@fallback.nil?
            break memo if memo.nil?

            memo.public_send(name)
          end
        end
      end
    end

    class SelfResolver < FieldResolver
      #: (Executor::ExecutionField[untyped], GraphQL::Query::Context) -> Array[untyped]
      def resolve(exec_field, _ctx)
        exec_field.map_objects(&:itself)
      end
    end

    class ValueResolver < FieldResolver
      #: untyped
      attr_reader :value

      #: (untyped) -> void
      def initialize(value)
        @value = value
      end

      #: (Executor::ExecutionField[untyped], GraphQL::Query::Context) -> Array[untyped]
      def resolve(exec_field, _ctx)
        exec_field.resolve_all(@value)
      end
    end
  end
end
