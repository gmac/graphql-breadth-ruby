# graphql-breadth Rack example

This is a small standalone Rack app that serves GraphiQL at `/` and executes GraphQL requests through `GraphQL::Breadth::Executor` at `/graphql`. It uses the [Scryfall API](https://scryfall.com/docs/api) as a remote backend.

```sh
cd example
bundle install
bundle exec rackup
```

Then open `http://localhost:9292`. The root redirects to `/query`.

The top nav switches between:

- `/query` for normal JSON query and mutation requests.
- `/defer` for `@defer` over SSE. GraphiQL's response pane shows the current merged result snapshot, while the "SSE Stream" panel shows the raw SSE timeline with receive timing.
- `/subscriptions` for subscriptions over SSE. The "Card Events" panel fills in a live list of raw events, and the top-right "Add Card" button runs the `addAnotherCard` mutation to publish to open subscriptions.

The stream routes start with GraphiQL's editor maximized so the operation is the main workspace while the right sidebar records each raw SSE payload as it arrives.

## JSON query

```sh
curl http://localhost:9292/graphql \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"{ magicCards { id name imageUri set { code name } } }"}'
```

## JSON mutation

```sh
curl http://localhost:9292/graphql \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"mutation { addAnotherCard { id name } }"}'
```

## Incremental `@defer` over SSE

```sh
curl -N http://localhost:9292/graphql \\
  -H 'Accept: text/event-stream' \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"{ magicCards { id name ... @defer(label: \"rulings\") { rulings { date comment } } } }"}'
```

## Incremental `@defer` over multipart

```sh
curl -N http://localhost:9292/graphql \\
  -H 'Accept: multipart/mixed' \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"{ magicCards { id name ... @defer(label: \"rulings\") { rulings { date comment } } } }"}'
```

## Subscription over SSE

```sh
curl -N http://localhost:9292/graphql \\
  -H 'Accept: text/event-stream' \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"subscription { cardAdded { id name } }"}'
```

Then add a card from another terminal:

```sh
curl http://localhost:9292/graphql \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"mutation { addAnotherCard { id name } }"}'
```
