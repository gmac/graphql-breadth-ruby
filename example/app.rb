# frozen_string_literal: true

require "erb"
require "json"
require "rack/request"
require "rack/response"
require "thread"

require_relative "lib/example/schema"

module Example
  class App
    GRAPHQL_PATH = "/graphql"
    EVENT_PATH = "/events/greeting"
    MULTIPART_BOUNDARY = "graphql"
    VIEW_ROOT = File.expand_path("views", __dir__)
    MODES = {
      "query" => {
        "path" => "/query",
        "label" => "Query/Mutation",
        "transport" => "json",
        "defaultQuery" => <<~GRAPHQL,
          query Hello($name: String) {
            hello(name: $name) {
              message
              sequence
            }
            serverTime
          }

          mutation Echo($message: String!) {
            echo(message: $message)
          }
        GRAPHQL
        "variables" => {
          "name" => "breadth",
          "message" => "Hello from a graphql-breadth mutation",
        },
      },
      "defer" => {
        "path" => "/defer",
        "label" => "Defer",
        "transport" => "sse",
        "defaultQuery" => <<~GRAPHQL,
          query DeferredHello($name: String, $outerDelay: Int, $innerDelay: Int) {
            hello(name: $name) {
              message
              ... @defer(label: "later") {
                delayed(seconds: $outerDelay)
                ... @defer(label: "later2") {
                  lazy: delayed(seconds: $innerDelay)
                }
              }
            }
          }
        GRAPHQL
        "variables" => {
          "name" => "breadth",
          "outerDelay" => 5,
          "innerDelay" => 10,
        },
        "inspector" => {
          "title" => "SSE Stream",
          "empty" => "Run the operation to see SSE payloads",
        },
      },
      "subscriptions" => {
        "path" => "/subscriptions",
        "label" => "Subscriptions",
        "transport" => "sse",
        "defaultQuery" => <<~GRAPHQL,
          subscription Greetings {
            greetings {
              message
              sequence
            }
          }
        GRAPHQL
        "variables" => {},
        "inspector" => {
          "title" => "SSE Events",
          "empty" => "Start the subscription, then send an event",
        },
        "trigger" => {
          "path" => EVENT_PATH,
          "label" => "Send Event",
        },
      },
    }.freeze
    NAV_ITEMS = MODES.map do |id, config|
      {
        "id" => id,
        "path" => config.fetch("path"),
        "label" => config.fetch("label"),
      }
    end.freeze

    class EventBus
      def initialize
        @mutex = Mutex.new
        @sequence = 0
        @subscribers = []
      end

      def subscribe
        queue = Queue.new

        @mutex.synchronize do
          @subscribers << queue
        end

        Enumerator.new do |events|
          begin
            loop do
              events << queue.pop
            end
          ensure
            @mutex.synchronize do
              @subscribers.delete(queue)
            end
          end
        end
      end

      def publish(name:)
        event = nil
        subscribers = nil

        @mutex.synchronize do
          @sequence += 1
          event = Example::Schema.greeting(name: name, sequence: @sequence)
          subscribers = @subscribers.dup
        end

        subscribers.each { |queue| queue << event }

        {
          "event" => event,
          "subscribers" => subscribers.length,
        }
      end
    end

    def initialize(event_bus: EventBus.new)
      @event_bus = event_bus
    end

    def call(env)
      request = Rack::Request.new(env)

      return redirect_response(MODES.fetch("query").fetch("path")) if request.get? && request.path_info == "/"

      if request.get?
        mode_id = mode_id_for_path(request.path_info)
        return graphiql_response(mode_id) if mode_id
      end

      return cors_response if request.options? && [GRAPHQL_PATH, EVENT_PATH].include?(request.path_info)
      return event_response(request) if request.post? && request.path_info == EVENT_PATH
      return graphql_response(request) if graphql_request?(request)

      json_response({ "errors" => [{ "message" => "Not found" }] }, status: 404)
    rescue JSON::ParserError
      json_response({ "errors" => [{ "message" => "Request body must be valid JSON" }] }, status: 400)
    rescue GraphQL::ParseError => error
      json_response({ "errors" => [error.to_h] }, status: 400)
    rescue StandardError => error
      json_response({ "errors" => [{ "message" => error.message }] }, status: 500)
    end

    private

    def graphql_request?(request)
      request.path_info == GRAPHQL_PATH && (request.get? || request.post?)
    end

    def graphql_response(request)
      params = graphql_params(request)
      document = GraphQL.parse(params.fetch("query", ""))
      validation_errors = Example::Schema::GRAPHQL_SCHEMA.validate(document)

      unless validation_errors.empty?
        return json_response({ "errors" => validation_errors.map(&:to_h) }, status: 400)
      end

      executor = Example::Schema.executor(
        document,
        variables: params.fetch("variables", {}),
        context: {
          request_id: request.get_header("HTTP_X_REQUEST_ID"),
          event_bus: @event_bus,
        },
      )

      if executor.subscription?
        return subscription_response(executor, request)
      end

      if accepts?(request, "text/event-stream")
        incremental = executor.incremental_result
        return sse_response(each_incremental_payload(incremental))
      end

      if accepts?(request, "multipart/mixed")
        incremental = executor.incremental_result
        return multipart_response(each_incremental_payload(incremental))
      end

      json_response(executor.result)
    end

    def subscription_response(executor, request)
      stream = executor.subscribe

      return json_response(stream, status: 400) if stream.is_a?(Hash)

      if accepts?(request, "multipart/mixed")
        multipart_response(stream.each)
      else
        sse_response(stream.each)
      end
    end

    def graphql_params(request)
      raw_params = if request.get?
        request.params
      elsif request.media_type == "application/graphql"
        { "query" => request.body.read }
      else
        body = request.body.read
        body.empty? ? {} : JSON.parse(body)
      end

      raw_params = stringify_keys(raw_params)
      raw_params["variables"] = parse_variables(raw_params["variables"])
      raw_params
    end

    def event_response(request)
      params = event_params(request)
      name = params.fetch("name", "SSE").to_s
      name = "SSE" if name.empty?

      json_response(@event_bus.publish(name: name))
    end

    def event_params(request)
      body = request.body.read
      body.empty? ? {} : stringify_keys(JSON.parse(body))
    end

    def parse_variables(value)
      case value
      when nil, ""
        {}
      when String
        JSON.parse(value)
      when Hash
        value
      else
        raise JSON::ParserError, "variables must be a JSON object"
      end
    end

    def stringify_keys(hash)
      hash.each_with_object({}) do |(key, value), out|
        out[key.to_s] = value
      end
    end

    def accepts?(request, content_type)
      request.get_header("HTTP_ACCEPT").to_s.include?(content_type)
    end

    def each_incremental_payload(result)
      Enumerator.new do |yielder|
        yielder << result.initial_result
        result.subsequent_results.each { |payload| yielder << payload }
      end
    end

    def sse_response(payloads)
      body = Enumerator.new do |yielder|
        payloads.each do |payload|
          yielder << "event: next\n"
          yielder << "data: #{JSON.generate(payload)}\n\n"
        end
        yielder << "event: complete\n"
        yielder << "data: {}\n\n"
      end

      [
        200,
        cors_headers.merge(
          "content-type" => "text/event-stream; charset=utf-8",
          "cache-control" => "no-cache",
          "x-accel-buffering" => "no",
        ),
        body,
      ]
    end

    def multipart_response(payloads)
      body = Enumerator.new do |yielder|
        payloads.each do |payload|
          yielder << "--#{MULTIPART_BOUNDARY}\r\n"
          yielder << "Content-Type: application/json; charset=utf-8\r\n\r\n"
          yielder << JSON.generate(payload)
          yielder << "\r\n"
        end
        yielder << "--#{MULTIPART_BOUNDARY}--\r\n"
      end

      [
        200,
        cors_headers.merge(
          "content-type" => "multipart/mixed; boundary=\"#{MULTIPART_BOUNDARY}\"",
        ),
        body,
      ]
    end

    def json_response(payload, status: 200)
      [
        status,
        cors_headers.merge("content-type" => "application/json; charset=utf-8"),
        [JSON.pretty_generate(payload)],
      ]
    end

    def graphiql_response(mode_id)
      Rack::Response.new(
        render_view(
          "graphiql",
          current_mode: mode_id,
          mode_config: MODES.fetch(mode_id),
          nav_items: NAV_ITEMS,
        ),
        200,
        cors_headers.merge("content-type" => "text/html; charset=utf-8"),
      ).finish
    end

    def redirect_response(location)
      [
        302,
        cors_headers.merge("location" => location),
        [],
      ]
    end

    def cors_response
      [204, cors_headers, []]
    end

    def cors_headers
      {
        "access-control-allow-origin" => "*",
        "access-control-allow-headers" => "Content-Type, Accept, X-Request-ID",
        "access-control-allow-methods" => "GET, POST, OPTIONS",
      }
    end

    def mode_id_for_path(path)
      MODES.find { |_, config| config.fetch("path") == path }&.first
    end

    def render_view(name, locals = {})
      template = ERB.new(File.read(File.join(VIEW_ROOT, "#{name}.erb")))
      view_binding = binding
      locals.each do |key, value|
        view_binding.local_variable_set(key, value)
      end
      template.result(view_binding)
    end
  end
end
