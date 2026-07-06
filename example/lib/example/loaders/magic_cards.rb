# frozen_string_literal: true

require "graphql/breadth"

require_relative "scryfall_helpers"

module Example
  module Loaders
    class MagicCards < GraphQL::Breadth::LazyLoader
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

      def perform_map(keys, _context)
        fetch_cards(keys)
      end

      private

      def fetch_cards(card_ids)
        body = JSON.generate(
          "identifiers" => card_ids.map { { "id" => _1 } },
        )

        fetch_scryfall_json("/cards/collection", method: :post, body: body)
          .fetch("data")
          .map { normalize_card(_1) }
      end
    end
  end
end
