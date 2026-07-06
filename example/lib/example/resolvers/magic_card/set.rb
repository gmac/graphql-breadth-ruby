# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_card_sets"

module Example
  module Resolvers
    module MagicCard
      class Set < GraphQL::Breadth::FieldResolver
        def resolve(exec_field, _context)
          exec_field.lazy(
            loader_class: Example::Loaders::MagicCardSets,
            keys: exec_field.objects.map { _1.fetch("setId") },
          )
        end
      end
    end
  end
end
