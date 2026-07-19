# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_cards"

module Example
  module Resolvers
    module Query
      class MagicCards < GraphQL::Breadth::FieldResolver
        def resolve(exec_field, _context)
          store = exec_field.objects.first
          card_ids = store.card_ids
          return exec_field.resolve_all([]) if card_ids.empty?

          cached_records = store
            .where(model: "MagicCard", ids: card_ids)
            .each_with_object({}) { |r, m| m[r.fetch("id").to_s] = r }

          exec_field.lazy(
            loader_class: Example::Loaders::MagicCards,
            keys: card_ids,
            eager_values: cached_records,
          ).then { exec_field.resolve_all(_1) }
        end
      end
    end
  end
end
