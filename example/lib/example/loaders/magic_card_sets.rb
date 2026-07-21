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

      def perform_map(set_ids, context)
        sets = async_map(set_ids) { fetch_set(_1) }
        context.fetch(:card_store).write(model: "MagicSet", records: sets)
      end

      def perform_one(set_id, context)
        set = fetch_set(set_id)
        context.fetch(:card_store).write(model: "MagicSet", records: [set])
        set
      end

      private

      def fetch_set(set_id)
        normalize_set(fetch_scryfall_json("/sets/#{set_id}"))
      end

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
