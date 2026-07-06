# frozen_string_literal: true

require "graphql/breadth"

require_relative "scryfall_helpers"

module Example
  module Loaders
    class MagicCardSets < GraphQL::Breadth::LazyLoader
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

      def perform_map(set_ids, _context)
        async_map(set_ids) { normalize_set(fetch_scryfall_json("/sets/#{_1}")) }
      end

      private

      def normalize_set(set)
        {
          "id" => set.fetch("id"),
          "code" => set.fetch("code"),
          "name" => set.fetch("name"),
          "uri" => set["scryfall_uri"] || set.fetch("uri"),
        }
      end
    end
  end
end
