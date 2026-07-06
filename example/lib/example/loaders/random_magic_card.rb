# frozen_string_literal: true

require "graphql/breadth"

require_relative "scryfall_helpers"

module Example
  module Loaders
    class RandomMagicCard < GraphQL::Breadth::LazyLoader
      include ScryfallHelpers

      async(
        limit: 10,
        resource: :scryfall_api,
        throttle: ScryfallHelpers::SCRYFALL_2_RPS,
        timeout: 10,
      )

      def map?
        true
      end

      def resolve_one?
        true
      end

      def perform_map(requests, _context)
        async_map(requests) do
          normalize_card(fetch_scryfall_json("/cards/random"))
        end
      end
    end
  end
end
