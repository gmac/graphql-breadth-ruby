# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_cards"

module Example
  module Resolvers
    module Subscription
      class CardAdded < GraphQL::Breadth::FieldResolver
        def subscribe(_exec_field, context)
          event_bus = context[:event_bus]

          raise GraphQL::ExecutionError, "No event bus configured" unless event_bus

          event_bus.subscribe
        end

        def resolve(exec_field, _context)
          card_ids = exec_field.objects.map { card_id_for(_1) }

          exec_field.lazy(
            loader_class: Example::Loaders::MagicCards,
            keys: card_ids,
          )
        end

        private

        def card_id_for(event)
          event.is_a?(Hash) ? event.fetch("card_id") : event
        end
      end
    end
  end
end
