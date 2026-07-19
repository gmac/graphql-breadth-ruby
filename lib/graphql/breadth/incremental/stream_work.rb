# typed: true
# frozen_string_literal: true

module GraphQL
  module Breadth
    module Incremental
      class StreamWork < Work
        #: Executor::ExecutionField[untyped]
        attr_reader :parent_field

        #: StreamDelivery
        attr_reader :delivery

        #: untyped
        attr_reader :item_type

        #: Array[untyped]
        attr_reader :remaining_items

        #: Integer
        attr_reader :initial_index

        #: (
        #|   parent_field: Executor::ExecutionField[untyped],
        #|   delivery: StreamDelivery,
        #|   item_type: untyped,
        #|   remaining_items: Array[untyped],
        #|   initial_index: Integer,
        #| ) -> void
        def initialize(parent_field:, delivery:, item_type:, remaining_items:, initial_index:)
          super()
          @parent_field = parent_field
          @delivery = delivery
          @item_type = item_type
          @remaining_items = remaining_items
          @initial_index = initial_index
          @entries = nil
        end

        #: -> bool
        def ready?
          @parent_field.scope.executed? && !@parent_field.scope.aborted?
        end

        #: (Coordinator) -> Array[Entry]
        def entries(_coordinator)
          @entries ||= @remaining_items.each_with_index.map do |object, offset|
            Entry.new(
              work: self,
              object:,
              path: [*@delivery.path, @initial_index + offset],
              index: offset,
            )
          end.freeze
        end

        #: -> singleton(GraphQL::Schema::Member)
        def parent_type
          @item_type.unwrap
        end

        #: -> Array[selection_node]
        def selections
          @parent_field.selections
        end

        #: -> Array[String]
        def scope_path
          @delivery.path
        end

        #: -> Array[String]
        def schema_path
          @parent_field.schema_path
        end

        #: -> Array[Executor::ExecutionDirective]
        def inherited_directives
          @parent_field.directives
        end

        #: -> untyped
        def cohort_key
          [self.class, @parent_field, @item_type]
        end
      end
    end
  end
end
