# frozen_string_literal: true

require "graphql/breadth"

require_relative "../../loaders/magic_card_rulings"

module Example
  module Resolvers
    module MagicCard
      class Rulings < GraphQL::Breadth::FieldResolver
        def resolve(exec_field, _context)
          exec_field.lazy(
            loader_class: Example::Loaders::MagicCardRulings,
            keys: exec_field.objects.map { _1.fetch("id") },
          )
        end
      end
    end
  end
end
