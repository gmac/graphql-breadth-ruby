# frozen_string_literal: true

require "erb"
require "json"
require "rack/request"
require "rack/response"

require_relative "lib/example/event_bus"
require_relative "lib/example/graphiql_view_data"
require_relative "lib/example/schema"

module Example
  class App
    GRAPHQL_PATH = "/graphql"
    MULTIPART_BOUNDARY = "graphql"
    VIEW_ROOT = File.expand_path("views", __dir__)

    def initialize(event_bus: EventBus.new, card_store: Example::Schema.card_store)
      @event_bus = event_bus
      @card_store = card_store
    end

    def call(env)
      request = Rack::Request.new(env)

      return redirect_response(GraphiQLViewData.default_path) if request.get? && request.path_info == "/"

      if request.get?
        view_data = GraphiQLViewData.for_path(request.path_info)
        return graphiql_response(view_data) if view_data
      end

      return cors_response if request.options? && request.path_info == GRAPHQL_PATH
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
        root_object: @card_store,
        operation_name: params["operationName"],
        context: {
          request_id: request.get_header("HTTP_X_REQUEST_ID"),
          event_bus: @event_bus,
        },
      )

      if executor.query.selected_operation.nil?
        return json_response({ "errors" => executor.query.static_errors.map(&:to_h) }, status: 400)

      elsif executor.subscription?
        return subscription_response(executor, request)

      elsif accepts?(request, "text/event-stream")
        incremental = executor.incremental_result
        return sse_response(each_incremental_payload(incremental))

      elsif accepts?(request, "multipart/mixed")
        incremental = executor.incremental_result
        return multipart_response(each_incremental_payload(incremental))
      end

      json_response(executor.result)
    end

    def subscription_response(executor, request)
      stream = executor.subscribe

      if stream.is_a?(Hash)
        json_response(stream, status: 400)
      elsif accepts?(request, "multipart/mixed")
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
      raw_params["operationName"] = nil if raw_params["operationName"].to_s.empty?
      raw_params
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

    def graphiql_response(view_data)
      Rack::Response.new(
        render_view("graphiql", view_data),
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
