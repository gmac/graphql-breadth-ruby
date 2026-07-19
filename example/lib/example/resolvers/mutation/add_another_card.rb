# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/random_magic_card"

module Example
  module Resolvers
    module Mutation
      class AddAnotherCard < GraphQL::Breadth::FieldResolver
        def resolve(exec_field, context)
          exec_field.lazy(
            loader_class: Example::Loaders::RandomMagicCard,
            keys: [Object.new],
          ).then do |card|
            card_id = card.fetch("id")
            store = exec_field.objects.first
            store.add(card_id)
            context[:event_bus]&.publish(card_id: card_id)
            exec_field.resolve_all(card)
          end
        end
      end
    end
  end
end
