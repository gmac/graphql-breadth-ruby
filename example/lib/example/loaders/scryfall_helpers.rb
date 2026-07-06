# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/limiter"
require "json"
require "protocol/http/request"

module Example
  module Loaders
    module ScryfallHelpers
      SCRYFALL_API_ROOT = "https://api.scryfall.com"
      SCRYFALL_HEADERS = {
        "accept" => "application/json",
        "user-agent" => "graphql-breadth example",
      }.freeze
      SCRYFALL_POST_HEADERS = SCRYFALL_HEADERS.merge(
        "content-type" => "application/json",
      ).freeze
      SCRYFALL_2_RPS = Async::Limiter::Generic.new(
        timing: Async::Limiter::Timing::SlidingWindow.new(
          1,
          Async::Limiter::Timing::Burst::Greedy,
          2,
        ),
      )
      SCRYFALL_10_RPS = Async::Limiter::Generic.new(
        timing: Async::Limiter::Timing::SlidingWindow.new(
          1,
          Async::Limiter::Timing::Burst::Greedy,
          10,
        ),
      )

      private

      def fetch_scryfall_json(path, method: :get, body: nil)
        Async::Task.current?&.yield

        endpoint = Async::HTTP::Endpoint["#{SCRYFALL_API_ROOT}#{path}"]
        stream = endpoint.connect
        connection = endpoint.protocol.client(stream)
        headers = method == :post ? SCRYFALL_POST_HEADERS : SCRYFALL_HEADERS
        request = ::Protocol::HTTP::Request[
          method.to_s.upcase,
          endpoint.path,
          headers,
          body,
          scheme: endpoint.scheme,
          authority: endpoint.authority,
        ]
        response = connection.call(request)
        payload = response.read

        unless response.success?
          raise GraphQL::ExecutionError, "Scryfall request failed with HTTP #{response.status}"
        end

        JSON.parse(payload)
      ensure
        response&.close

        if connection
          connection.close
        else
          stream&.close
        end
      end

      def normalize_card(card)
        {
          "id" => card.fetch("id"),
          "name" => card.fetch("name"),
          "uri" => card["scryfall_uri"] || card.fetch("uri"),
          "imageUri" => image_uri_for(card),
          "setId" => card.fetch("set_id"),
        }
      end

      def image_uri_for(card)
        image_uris = card["image_uris"] || card.dig("card_faces", 0, "image_uris")
        image_uris&.fetch("small", nil) || image_uris&.fetch("normal", nil)
      end
    end
  end
end
