# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_cards"

module Example
  module Resolvers
    module Query
      class MagicCards < GraphQL::Breadth::FieldResolver
        def resolve(exec_field, _context)
          card_ids = exec_field.objects.first.card_ids
          return exec_field.resolve_all([]) if card_ids.empty?

          exec_field.lazy(
            loader_class: Example::Loaders::MagicCards,
            keys: card_ids,
          ).then do |results|
            exec_field.resolve_all(results)
          end
        end
      end
    end
  end
end
