# graphql-breadth Rack example

This is a small standalone Rack app that serves GraphiQL at `/` and executes GraphQL requests through `GraphQL::Breadth::Executor` at `/graphql`.

```sh
cd example
bundle install
bundle exec rackup
```

Then open `http://localhost:9292`. The root redirects to `/query`.

The top nav switches between:

- `/query` for normal JSON query and mutation requests.
- `/defer` for `@defer` over SSE. GraphiQL's response pane shows the current merged result snapshot, while the "SSE Stream" panel shows the raw SSE timeline with receive timing.
- `/subscriptions` for subscriptions over SSE. The "SSE Events" panel fills in a live list of raw events, and the top-right "Send Event" button broadcasts a server event to open subscriptions.

The stream routes start with GraphiQL's editor maximized so the operation is the main workspace while the right sidebar records each raw SSE payload as it arrives.

The `Greeting.delayed(seconds:)` field accepts an integer sleep duration. The defer example uses five seconds for the outer deferred field and ten seconds for the nested one so each payload is easy to see.

## JSON query

```sh
curl http://localhost:9292/graphql \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"{ hello(name: \"Rack\") { message delayed(seconds: 0) sequence } }"}'
```

## JSON mutation

```sh
curl http://localhost:9292/graphql \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"mutation { echo(message: \"Hello mutation\") }"}'
```

## Incremental `@defer` over SSE

```sh
curl -N http://localhost:9292/graphql \\
  -H 'Accept: text/event-stream' \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"{ hello { message ... @defer(label: \"later\") { delayed(seconds: 5) ... @defer(label: \"later2\") { lazy: delayed(seconds: 10) } } } }"}'
```

## Incremental `@defer` over multipart

```sh
curl -N http://localhost:9292/graphql \\
  -H 'Accept: multipart/mixed' \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"{ hello { message ... @defer(label: \"later\") { delayed(seconds: 5) ... @defer(label: \"later2\") { lazy: delayed(seconds: 10) } } } }"}'
```

## Subscription over SSE

```sh
curl -N http://localhost:9292/graphql \\
  -H 'Accept: text/event-stream' \\
  -H 'Content-Type: application/json' \\
  -d '{"query":"subscription { greetings { message sequence } }"}'
```

Then trigger events from another terminal:

```sh
curl http://localhost:9292/events/greeting \\
  -H 'Content-Type: application/json' \\
  -d '{"name":"SSE"}'
```
