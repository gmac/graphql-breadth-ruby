# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_card_sets"

module Example
  module Resolvers
    module MagicCard
      class Set < GraphQL::Breadth::FieldResolver
        def resolve(exec_field, context)
          store = context.fetch(:card_store)
          set_ids = exec_field.objects.map { _1.fetch("setId") }
          cached_records = store
            .where(model: "MagicSet", ids: set_ids)
            .each_with_object({}) { |r, m| m[r.fetch("id").to_s] = r }

          exec_field.lazy(
            loader_class: Example::Loaders::MagicCardSets,
            keys: set_ids,
            eager_values: cached_records,
          )
        end
      end
    end
  end
end
