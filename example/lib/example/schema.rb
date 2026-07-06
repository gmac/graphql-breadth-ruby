# frozen_string_literal: true

require "graphql/breadth"
require "set"

GraphQL::Breadth.enable_async!

module Example
  module Schema
    SDL = <<~GRAPHQL
      directive @defer(if: Boolean, label: String) on INLINE_FRAGMENT | FRAGMENT_SPREAD

      schema {
        query: Query
        mutation: Mutation
        subscription: Subscription
      }

      type MagicCard {
        id: ID!
        name: String!
        uri: String!
        imageUri: String!
        set: MagicSet
        rulings: [MagicCardRuling!]
      }

      type MagicSet {
        id: ID!
        code: String!
        name: String!
        uri: String!
      }

      type MagicCardRuling {
        date: String!
        comment: String!
      }

      type Query {
        magicCards: [MagicCard!]!
      }

      type Mutation {
        addAnotherCard: MagicCard!
      }

      type Subscription {
        cardAdded: MagicCard!
      }
    GRAPHQL

    GRAPHQL_SCHEMA = GraphQL::Schema.from_definition(SDL)

    require_relative "card_store"
    require_relative "resolvers/query/magic_cards"
    require_relative "resolvers/mutation/add_another_card"
    require_relative "resolvers/subscription/card_added"
    require_relative "resolvers/magic_card/set"
    require_relative "resolvers/magic_card/rulings"

    RESOLVERS = {
      "Query" => {
        "magicCards" => Example::Resolvers::Query::MagicCards.new,
      },
      "Mutation" => {
        "addAnotherCard" => Example::Resolvers::Mutation::AddAnotherCard.new,
      },
      "Subscription" => {
        "cardAdded" => Example::Resolvers::Subscription::CardAdded.new,
      },
      "MagicCard" => {
        "id" => GraphQL::Breadth::HashKeyResolver.new("id"),
        "name" => GraphQL::Breadth::HashKeyResolver.new("name"),
        "imageUri" => GraphQL::Breadth::HashKeyResolver.new("imageUri"),
        "uri" => GraphQL::Breadth::HashKeyResolver.new("uri"),
        "set" => Example::Resolvers::MagicCard::Set.new,
        "rulings" => Example::Resolvers::MagicCard::Rulings.new,
      },
      "MagicSet" => {
        "id" => GraphQL::Breadth::HashKeyResolver.new("id"),
        "code" => GraphQL::Breadth::HashKeyResolver.new("code"),
        "name" => GraphQL::Breadth::HashKeyResolver.new("name"),
        "uri" => GraphQL::Breadth::HashKeyResolver.new("uri"),
      },
      "MagicCardRuling" => {
        "date" => GraphQL::Breadth::HashKeyResolver.new("date"),
        "comment" => GraphQL::Breadth::HashKeyResolver.new("comment"),
      },
    }.freeze

    module_function

    def card_store
      @card_store ||= CardStore.new
    end

    def executor(document, variables: {}, context: {}, root_object: card_store, operation_name: nil)
      GraphQL::Breadth::Executor.new(
        GRAPHQL_SCHEMA,
        document,
        resolvers: RESOLVERS,
        root_object: root_object,
        variables: variables,
        context: context,
        operation_name: operation_name,
      )
    end
  end
end
