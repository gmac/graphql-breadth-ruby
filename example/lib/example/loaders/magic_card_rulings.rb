# frozen_string_literal: true

require "graphql/breadth"

require_relative "scryfall_helpers"

module Example
  module Loaders
    class MagicCardRulings < GraphQL::Breadth::LazyLoader
      include ScryfallHelpers

      async(
        limit: 10,
        resource: :scryfall_api,
        throttle: ScryfallHelpers::SCRYFALL_10_RPS,
        timeout: 10,
      )

      def map?
        true
      end

      def perform_map(card_ids, context)
        rulings = async_map(card_ids) do |card_id|
          fetch_scryfall_json("/cards/#{card_id}/rulings")
            .fetch("data")
            .map { normalize_ruling(_1) }
        end

        records = card_ids.zip(rulings).map do |card_id, card_rulings|
          { "id" => card_id, "rulings" => card_rulings }
        end
        context.fetch(:card_store).write(model: "MagicCardRulings", records: records)
        rulings
      end

      private

      def normalize_ruling(ruling)
        {
          "date" => ruling.fetch("published_at"),
          "comment" => ruling.fetch("comment"),
        }
      end
    end
  end
end
