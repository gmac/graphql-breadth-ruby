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

        #: Stream::Session
        attr_reader :session

        #: Integer
        attr_reader :position

        #: (
        #|   parent_field: Executor::ExecutionField[untyped],
        #|   delivery: StreamDelivery,
        #|   item_type: untyped,
        #|   session: Stream::Session,
        #|   position: Integer,
        #|   initial_index: Integer,
        #| ) -> void
        def initialize(parent_field:, delivery:, item_type:, session:, position:, initial_index:)
          super()
          @parent_field = parent_field
          @delivery = delivery
          @item_type = item_type
          @session = session
          @position = position
          @next_index = initial_index
          @items = nil
          @entries = nil
          @complete_after_batch = false
          @source_error = nil
        end

        #: -> bool
        def ready?
          !!(@items && !@items.empty?) && @parent_field.scope.executed? && !@parent_field.scope.aborted?
        end

        #: -> bool
        def announceable?
          !executed? && @parent_field.scope.executed? && !@parent_field.scope.aborted?
        end

        #: -> bool
        def batch_pending?
          !!@items
        end

        #: (Array[untyped], ?complete: bool) -> void
        def load_batch(items, complete: false)
          raise ImplementationError, "Cannot replace an unconsumed stream batch" if @items

          @items = items
          @entries = nil
          @complete_after_batch = complete
        end

        #: -> void
        def complete!
          @executed = true
        end

        #: (StandardError) -> void
        def fail!(error)
          @source_error = error
          complete!
        end

        #: -> StandardError?
        def source_error
          @source_error
        end

        #: -> void
        def finish_batch!
          @next_index += @items&.length || 0
          @items = nil
          @entries = nil
          complete! if @complete_after_batch
          @complete_after_batch = false
        end

        #: (Coordinator) -> Array[Entry]
        def entries(_coordinator)
          items = @items || EMPTY_ARRAY
          @entries ||= items.each_with_index.map do |object, offset|
            Entry.new(
              work: self,
              object:,
              path: [*@delivery.path, @next_index + offset],
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
