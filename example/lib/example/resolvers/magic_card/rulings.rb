# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_card_rulings"

module Example
  module Resolvers
    module MagicCard
      class Rulings < GraphQL::Breadth::FieldResolver
        def resolve(exec_field, context)
          store = context.fetch(:card_store)
          card_ids = exec_field.objects.map { _1.fetch("id") }
          cached_records = store
            .where(model: "MagicCardRulings", ids: card_ids)
            .each_with_object({}) { |r, m| m[r.fetch("id").to_s] = r.fetch("rulings") }

          exec_field.lazy(
            loader_class: Example::Loaders::MagicCardRulings,
            keys: card_ids,
            eager_values: cached_records,
          )
        end
      end
    end
  end
end
