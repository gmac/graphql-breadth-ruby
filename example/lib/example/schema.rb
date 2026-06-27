# frozen_string_literal: true

require "graphql/breadth"
require "time"

module Example
  module Schema
    SDL = <<~GRAPHQL
      schema {
        query: Query
        mutation: Mutation
        subscription: Subscription
      }

      directive @defer(if: Boolean = true, label: String) on FRAGMENT_SPREAD | INLINE_FRAGMENT

      type Query {
        hello(name: String = "world"): Greeting!
        serverTime: String!
      }

      type Mutation {
        echo(message: String!): String!
      }

      type Subscription {
        greetings: Greeting!
      }

      type Greeting {
        message: String!
        delayed(seconds: Int = 5): String!
        sequence: Int!
      }
    GRAPHQL

    GRAPHQL_SCHEMA = GraphQL::Schema.from_definition(SDL)

    class HelloResolver < GraphQL::Breadth::FieldResolver
      def resolve(exec_field, _context)
        name = exec_field.arguments[:name] || "world"
        exec_field.resolve_all(Example::Schema.greeting(name: name, sequence: 1))
      end
    end

    class ServerTimeResolver < GraphQL::Breadth::FieldResolver
      def resolve(exec_field, _context)
        exec_field.resolve_all(Time.now.utc.iso8601)
      end
    end

    class EchoResolver < GraphQL::Breadth::FieldResolver
      def resolve(exec_field, _context)
        exec_field.resolve_all(exec_field.arguments.fetch(:message))
      end
    end

    class DelayedResolver < GraphQL::Breadth::FieldResolver
      def resolve(exec_field, _context)
        seconds = exec_field.arguments[:seconds]
        seconds = 5 if seconds.nil?
        seconds = [seconds.to_i, 0].max

        sleep seconds
        exec_field.map_objects { "Delivered after #{seconds} seconds by graphql-breadth @defer." }
      end
    end

    class GreetingsSubscriptionResolver < GraphQL::Breadth::FieldResolver
      def subscribe(_exec_field, context)
        event_bus = context[:event_bus]

        raise GraphQL::ExecutionError, "No event bus configured" unless event_bus

        event_bus.subscribe
      end

      def resolve(exec_field, _context)
        exec_field.map_objects(&:itself)
      end
    end

    RESOLVERS = {
      "Query" => {
        "hello" => HelloResolver.new,
        "serverTime" => ServerTimeResolver.new,
      },
      "Mutation" => {
        "echo" => EchoResolver.new,
      },
      "Subscription" => {
        "greetings" => GreetingsSubscriptionResolver.new,
      },
      "Greeting" => {
        "message" => GraphQL::Breadth::HashKeyResolver.new("message"),
        "delayed" => DelayedResolver.new,
        "sequence" => GraphQL::Breadth::HashKeyResolver.new("sequence"),
      },
    }.freeze

    module_function

    def executor(document, variables: {}, context: {})
      GraphQL::Breadth::Executor.new(
        GRAPHQL_SCHEMA,
        document,
        resolvers: RESOLVERS,
        root_object: {},
        variables: variables,
        context: context,
      )
    end

    def greeting(name:, sequence:)
      {
        "message" => "Hello, #{name}!",
        "delayed" => "Delivered later by graphql-breadth @defer.",
        "sequence" => sequence,
      }
    end
  end
end
