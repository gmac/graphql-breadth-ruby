# Breadth-first GraphQL execution

_**The core algorithm backing Shopify's _GraphQL Cardinal_ engine.** Learn more about the breadth-first GraphQL design advantages in the [blog post](https://shopify.engineering/faster-breadth-first-graphql-execution). For a typescipt port, see [graphql-breadth-js](https://github.com/gmac/graphql-breadth-js)._

* Runs field executions breadth-first, layer by layer (versus depth-first, tree by tree).
* Individual resolvers are implicitly batched.
* Lazy resolvers sharing I/O bind entire object sets to a single promise.
* Processes via queuing rather than recursion.

```
ruby 3.2.1 (2023-02-08 revision 31819e82c8) +YJIT [arm64-darwin23]

Non-lazy comparison:
graphql-breadth: 1000 x 3 scalars:     1257.1 i/s
graphql-ruby resolve_batch: 1000 x 3 scalars:      773.2 i/s - 1.63x  slower
graphql-ruby classic: 1000 x 3 scalars:      102.0 i/s - 12.32x  slower

Lazy comparison:
graphql-breadth LazyLoader: 1000 x 1 lazy scalar:     2469.5 i/s
graphql-ruby execute_next + dataloader: 1000 x 1 lazy scalar:      533.1 i/s - 4.63x  slower
graphql-ruby execute_next + graphql-batch: 1000 x 1 lazy scalar:      291.7 i/s - 8.47x  slower
graphql-ruby graphql-batch: 1000 x 1 lazy scalar:      178.7 i/s - 13.82x  slower
graphql-ruby dataloader: 1000 x 1 lazy scalar:      114.6 i/s - 21.56x  slower
```

# Support

The core execution algorithm is proven at scale in production. Subscriptions and incremental delivery (`@defer` and `@stream`) are experimental. Other limitations:

* Currently no built-in validation or analysis, do it ahead of time.
* Supports input validations, but intentionally omits input prepare hooks. Holistically prepare inputs in resolvers.

# Usage

## Execute a query

```ruby
executor = GraphQL::Breadth::Executor.new(
  MyGraphQLSchema,
  GraphQL.parse(document),
  operation_name: "GetWidgets",
  root_object: { ... },
  variables: { ... },
  context: { ... },
  tracers: [ ... ],
)

result = executor.result
```

## Execution taxonomy

A request document gets built into an execution tree. This taxonomy is provided during execution for sequencing actions. A request like this:

```graphql
query {
  products(first: 10) {
    nodes {
      id
      title
    }
  }
}
```

Gets built into an execution tree structured as the following pseudocode:

```ruby
ExecutionScope.new(type: QueryRoot, fields: [
  ExecutionField.new(key: "products", ExecutionScope.new(type: ProductConnection, fields: [
    ExecutionField.new(key: "nodes", ExecutionScope.new(type: Product, fields: [
      ExecutionField.new(key: "id"),
      ExecutionField.new(key: "title"),
    ]))
  ]))
])
```

This taxonomy provides the following API, which is useful while writing resolver behaviors:

* **`ExecutionField`**: represents a field to execute within a resolved object scope.
  - `path`: the selection path leading to the field, composed of namespaces with no list indices.
  - `key`: the namespace assigned by the field's selection alias or definition name.
  - `type`: the GraphQL return type of the field, may be abstract with non-null and list wrappers.
  - `objects`: the field's frozen object set. All fields share this set with their scope.
  - `arguments`: a frozen hash of arguments provided to the selection. Argument keys are `:snake_case` symbols. Argument "prepare" hooks are intentionally not supported; argument formatting should be done holistically in the resolver.
  - `mutable_arguments`: a mutable clone of the arguments hash that can be modified.
  - `definition`: the associated GraphQL field definition. For schema reference only (avoid repurposing legacy implementation details).
  - `scope`: the parent execution scope that this field belongs to.
  - `resolve_all(<value>)`: resolves a value mapped to all field objects. Useful for early returns.
  - `preload(<LazyLoader>, keys: [...]?, args: { ... }?)`: Registers a lazy preloader to run before the field executes. May only be called by field planner methods.
  - `lazy(<LazyLoader>?, keys: [...], args: { ... }?)`: defers to lazy execution and returns a Promise. May only be called by field resolver methods.
  - `attributes`: a hash intended for local caching and freeform planning notes.
  - `attribute(<name>)`: reads an attribute without allocating storage.
  - `attribute?(<name>)`: checks an attribute without allocating storage.
* **`ExecutionScope`**: represents a resolved object scope with a known concrete object type.
  - `path`: selection path leading to the scope, composed of namespaces with no list indices.
  - `objects`: the scopes's frozen object set.
  - `parent`: the execution scope above this one.
  - `parent_field`: the execution field in the parent scope that opened this scope.
  - `parent_type`: the GraphQL object type of the scope. This is always a resolved object type, never an abstract interface or union.
  - `abstraction`: for scopes resolved through an interface or union, this details characteristics of that abstraction.
  - `preload(<LazyLoader>, keys: [...]?, args: { ... }?)`: Registers a lazy preloader to run before the scope executes. May only be called by planner methods.
  - `attributes`: a hash intended for local caching and freeform planning notes.
  - `attribute(<name>)`: reads an attribute without allocating storage.
  - `attribute?(<name>)`: checks an attribute without allocating storage.

**An execution tree can only be traversed from the bottom-up**. This is extremely intentional, because traversing top-down can never see through unresolved abstractions.

## Field resolvers

For each field implementation, set up a `GraphQL::Breadth::FieldResolver`:

```ruby
class MyFieldResolver < GraphQL::Breadth::FieldResolver
   def resolve(exec_field, context)
      exec_field.map_objects { |object| object.some_method }
   end
end
```

A field resolver receives `exec_field` and `context`. The execution field provides `objects` and `arguments`, along with [many other useful properties](#execution-taxonomy).

A resolver **must return a mapped set of results** for the field's objects, or invoke a [lazy resolver hook](#lazy-resolvers). To attach a field resolver to a field, use the `GraphQL::Breadth::HasBreadthResolver` field mixin:

```ruby
class BaseField < GraphQL::Schema::Field
  include GraphQL::Breadth::HasBreadthResolver::Field
end

class BaseObject < GraphQL::Schema::Object
  field_class BaseField
end

class MyObject < BaseObject
  field :featured_products, -> { [Product] } do |f|
    f.breadth_resolver = MyFieldResolver.new
  end
end
```

Alternatively, you can manage field implementations using a resolver map:

```ruby
RESOLVER_MAP = {
  "Query" => {
    "widget" => WidgetResolver.new,
  },
  "Widget" => {
    "id" => GraphQL::Breadth::MethodResolver.new(:id),
  }
}.freeze

executor = GraphQL::Breadth::Executor.new(
  MyGraphQLSchema,
  GraphQL.parse(document),
  resolvers: RESOLVER_MAP,
)
```

### Built-in resolvers

The core library includes several basic resolvers for common needs:

* `GraphQL::Breadth::MethodResolver.new(:method_to_call, ...)` (chained methods)
* `GraphQL::Breadth::HashKeyResolver.new("some_key")` (symbol or string key)
* `GraphQL::Breadth::ValueResolver.new(true)` (static value)
* `GraphQL::Breadth::SelfResolver.new` (resolves original objects)

### Early return

Field resolvers may return early with a value for all objects using `resolve_all`. This is commonly used to resolve `nil` or an eager value across all field objects.

```ruby
class MyFieldResolver < GraphQL::Breadth::FieldResolver
   def resolve(exec_field, context)
      return exec_field.resolve_all(nil) if exec_field.arguments[:key].nil?

      # otherwise... resolve something else
   end
end
```

### Error handling

To error out specific object positions within a field, error instances must be mapped into the field's result set. Use the `handle_or_reraise` helper within a StandardError rescue block to optimally handle raised mapping errors:

```ruby
class MyFieldResolver < GraphQL::Breadth::FieldResolver
   def resolve(exec_field, context)
      exec_field.objects.map do |obj|
        obj.valid? ? obj.my_field : GraphQL::ExecutionError.new("Not valid")
      rescue StandardError => e
        exec_field.handle_or_reraise(e)
      end
   end
end
```

This pattern is so common that it's provided as the `map_objects` helper. Just remember when calling `map_objects` that the results may include inlined error positions:

```ruby
class MyFieldResolver < GraphQL::Breadth::FieldResolver
   def resolve(exec_field, context)
      exec_field.map_objects(&:do_stuff!) # << maps to results OR inlined errors
   end
end
```

Any error raised during field execution _outside_ of a rescued mapping loop will result in all field objects receiving the same error:

```ruby
class MyFieldResolver < GraphQL::Breadth::FieldResolver
   def resolve(exec_field, context)
      raise GraphQL::ExecutionError.new("no key") if exec_field.arguments[:key].nil?

      exec_field.map_objects(&:do_stuff!)
   end
end
```

### Resolver caches

Field resolvers may build and cache resources to be shared with other fields across their scope using `attributes`. Both execution fields and their scopes support setting attributes:

```ruby
class MyFieldResolver < GraphQL::Breadth::FieldResolver
   def resolve(exec_field, context)
      # cache wrapped objects on the parent scope...
      wrapped_objects = exec_field.scope.attributes[:wrapped_objects] ||= begin
        exec_field.objects.map { |obj| MyWrapper.new(obj) }
      end

      wrapped_objects.map(&:wrapper_method)
   end
end
```

When reading attributes, prefer using `element.attribute(key)` to avoid allocating unnecessary storage.

## Lazy resolvers

Breadth field resolvers receive sets, which provides implicit batching for a single field instance. However, this doesn't take into account the same field loading at multiple document positions, or different fields sharing a query. For example:

```graphql
query {
  product(id: "1") {
    featuredMedia {
      ...on Image { sources } # loads image sources
    }
    media(first: 10) {
      nodes {
        ...on Image { sources } # loads image sources
      }
    }
  }
}
```

In the above, we'll want `Image.sources` to batch across all instances of the field, even at different document depths. LazyLoader solves this – which is breadth's analog to traditional dataloaders. Unlike traditional dataloaders though, a breadth LazyLoader binds entire key sets to a single promise, rather than building 1:1 promises. This dramatically reduces lazy overhead.

### Lazy loaders

Queries shared across separate fields or multiple instances of the same field need a common LazyLoader class.

```ruby
class SharedLoader < GraphQL::Breadth::LazyLoader
  def initialize(group:)
    super()
    @group = group
  end

  def perform(ids, context)
    Thing.where(parent_id: ids, group: @group).to_a.each do |thing|
      fulfill_key(thing.parent_id, thing)
    end
  end
end

class SharedLazyResolver < GraphQL::Breadth::FieldResolver
  def resolve(exec_field, context)
    mapped_keys = exec_field.objects.map { |obj| obj.valid? ? obj.id : nil }

    exec_field
      .lazy(SharedLoader, args: { group: "a" }, keys: mapped_keys)
      .then do |loaded_records|
        loaded_records.map! { |record| record&.my_field }
      end
  end
end
```

Here `exec_field.lazy` is called with a LazyLoader class. Within a loader class, call `fulfill_key` to deliver each loaded record. Lazy loaders do NOT require fulfillment of each provided key; unfulfilled keys simply return as `nil`. You can also set up a lazy loader class to fulfill by mapped set, although this frequently adds a mapping layer that calling `fulfill_key` directly would avoid:

```ruby
class MapLoader < GraphQL::Breadth::LazyLoader
  def map? = true

  def perform_map(keys, context)
    things_by_key = Thing.where(parent_id: keys).index_by(&:parent_id)
    keys.map { |key| things_by_key[key] }
  end
end
```

### Nil keys

It's extremely common for a mapped set of lazy keys to have `nil` positions that must be retained to match the resolver's breadth set. These nil keys should almost never be loaded, so they are omitted from batching and resolve as nil by default. If you specifically want to treat nil as a loadable value, specify `load_nil_keys: true`.

```ruby
class MaybeNilKeysResolver < GraphQL::Breadth::FieldResolver
  def resolve(exec_field, context)
    mapped_keys = exec_field.objects.map { |obj| obj.ready? ? obj.id : nil }

    exec_field.lazy(keys: mapped_keys, load_nil_keys: true)
  end

  def perform_lazy(keys, args, context)
    # ... keys may include nil!
  end
end
```

### Eager values

In many cases, a resolver can eagerly evaluate the result of some keys. Use `eager_values` to inject pre-resolved values into a lazy loader:

```ruby
class MaskingResolver < GraphQL::Breadth::FieldResolver
  def resolve(exec_field, _context)
    eager_values = {}
    mapped_keys = exec_field.objects.map do |obj|
      # statically resolve "zebra" key as "HORSE"...
      eager_values[obj.key] = "HORSE" if obj.key == "zebra"
      obj.key
    end

    exec_field.lazy(keys: mapped_keys, eager_values: eager_values)
  end

  def perform_lazy(keys, args, context)
    # ... keys won't include "zebra"
  end
end
```

Eager values are specific to their field instance and will _not_ be shared by fields [using the same loader](#shared-lazy-loading). Eager values override the loader cache, so a specific field instance may eagerly resolve its own value for a key while other fields sharing the loader will still load the key as normal.

### LazyLoader keys vs identities

Lazy loaders support passing any complex object as loader keys. These complex objects can be reduced to a primitive identity within the loader's internal mapping table using the `identity_for` hook:

```ruby
class IdentityLoader < GraphQL::Breadth::LazyLoader
  def identity_for(key)
    "#{key.path}/#{key.handle}"
  end

  def perform(keys, context)
    Thing.load_by_references(keys).each do |thing|
      fulfill_identity("#{thing.path}/#{thing.handle}", thing)
    end
  end
end
```

Later on, it may be simpler to derive the same identity via the loaded result and deliver it via `fulfill_identity` rather than trying to map the record back to a complex key.

### Awaiting and chaining

Multiple loads can be built and awaited:

```ruby
class AwaitingResolver < GraphQL::Breadth::FieldResolver
  def resolve(exec_field, _context)
    keys = exec_field.objects.map(&:key)

    a = exec_field.lazy(PrefixLoader, args: { prefix: "a" }, keys: keys)
    b = exec_field.lazy(PrefixLoader, args: { prefix: "b" }, keys: keys)

    exec_field
      .await_all([a, b])
      .then do |results_a, results_b|
        exec_field.objects.map.with_index do |i|
          "#{results_a[i]} + #{results_b[i]}"
        end
      end
  end
end
```

Lazy sequencing can be chained:

```ruby
class ChainingResolver < GraphQL::Breadth::FieldResolver
  def resolve(exec_field, _context)
    exec_field
      .lazy(PrefixLoader, args: { prefix: "a" }, keys: exec_field.objects.map(&:key))
      .then { |results_a| exec_field.lazy(PrefixLoader, args: { prefix: "b" }, keys: results_a) }
      .then { |results_b| results_b.map { |b| "#{b}-fin" } }
  end
end
```

### Loader concurrency

Lazy loaders may engage Ruby's fiber-based concurrency to asynchronously queue scheduler-compatible I/O, such as `async-http` requests (CPU-bound work and thread-blocking clients cannot be parallelized). Running the Ruby scheduler is not free, so loaders must manually opt into async workflows when designed to leverage them.

#### Install

Lazy concurrency requires the `async` gem as an opt-in dependency. Add `async` to your Gemfile and then enable it with an initializer:

```ruby
# Gemfile
gem "async", "~> 2.0"

# config/initializers/graphql_breadth.rb
GraphQL::Breadth.enable_async!
```

#### Async loaders

A LazyLoader class may opt into asynchronous execution by calling `async` with concurrency settings. All async loader classes will parallelize during common lazy execution cycles:

```ruby
class RemoteInventoryLoader < GraphQL::Breadth::LazyLoader
  async resource: :inventory_api, limit: 4, timeout: 2

  def perform(keys, context)
    client = context[:inventory_client]

    keys.each do |key|
      fulfill_key(key, client.fetch_inventory(key))
    end
  end
end
```

All concurrency settings are optional:

* `resource: Symbol`, coordinates limits across related loaders hitting the same upstream resource. Defaults to a unique resource identity per loader class.
* `limit: Integer`, number of concurrent operations allowed while hitting the resource. Defaults to 8.
* `timeout: Integer`, number of seconds to wait on load operations before timing out. Defaults to none.
* `throttle`, an [async-limiter](https://github.com/socketry/async-limiter) that throttles rate. Defaults to none.

#### Async fan-out

Async LazyLoader classes may also fan-out their internal implementations using the `async` _instance_ method.

```ruby
class RemoteInventoryLoader < GraphQL::Breadth::LazyLoader
  # class is async across lazy loaders...
  async resource: :inventory_api, limit: 8, timeout: 2

  def perform(keys, context)
    client = context[:inventory_client]
    futures_by_key = keys.each_with_object({}) do |key, memo|
      # internals add async fan-out...
      memo[key] = async { client.fetch_inventory(key) }
    end

    futures_by_key.each_pair do |key, future|
      fulfill_key(key, future.wait)
    end
  end
end
```

There's also an `async_map` variation available:

```ruby
class RemoteInventoryLoader < GraphQL::Breadth::LazyLoader
  async resource: :inventory_api, limit: 8, timeout: 2

  def map? = true

  def perform_map(keys, context)
    client = context[:inventory_client]
    async_map(keys) { |key| client.fetch_inventory(key) }
  end
end
```

These fan-out instance methods share resource budgeting with their loader class by default. They can also specify their own `resource:`, `limit:`, and/or `timeout:` arguments to manage separate budgets from their loader class:

```ruby
async_map(keys, resource: :sprockets, limit: 3) { |key| client.fetch_inventory(key) }
```

## Query planning

The breadth executor operates on an [execution tree](#execution-taxonomy) in three phases:

1. The execution tree is built from top-down, omitting abstract positions.
2. A planning pass runs from bottom-up on the constructed tree. Fields may register actions on their ancestors.
3. The final execution pass runs from top-down, performing planned actions when encountered.

These three phases repeat each time an abstract position is resolved to build, plan, and execute its resulting subtree. The planning phase allows fields to consider their place within the execution tree and plan accordingly.

### Planning hooks

A field resolver may define a `plan` method that runs during the field's planning phase. This hook may register preloads and/or make tree annotations. Its return value is never captured or used.

```ruby
class WidgetResolver < GraphQL::Breadth::FieldResolver
  def plan(exec_field, context)
    exec_field.preload(AssociationLazyLoader, args: { association: :sprockets })
  end

  def resolve(exec_field, context)
    # resolve the field...
  end
end
```

### Lazy preloads

Both execution scopes and fields may bind lazy loaders during the planning phase that will perform preloads before the element executes. Use the `preload` method:

```ruby
class AssociationPreload < GraphQL::Breadth::LazyLoader
  def initialize(association:)
    super()
    @association = association
  end

  def perform(objects, context)
    ActiveRecord::Associations::Preloader.new(records: objects, associations: @association).call
    objects.each { |obj| fulfill_key(obj, obj.public_send(@association)) }
  end
end

class WidgetResolver < GraphQL::Breadth::FieldResolver
  def plan(exec_field, context)
    exec_field.preload(AssociationPreload, args: { association: :sprockets })
    # or ...
    exec_field.scope.preload(AssociationPreload, args: { association: :sprockets })
  end
end
```

The `preload` method can ONLY be called from within a `plan` hook and its chained preload callbacks, which all run prior to the element executing. Calling `preload` within a field resolver after execution starts will raise a `LazySequencingError`.

**Preloading Scopes vs Fields**

All fields share objects with their scope, so preloading at either level achieves a similar result. However, the timing is subtly different. Preloading a _scope_ will block entering the scope until its preloads are complete; preloading on a _field_ will only block the field itself while allowing sibling fields in the scope to be traversed, thus allowing the discovery of other batching targets among sibling subtrees.

So – scope preloads are useful for loading authorization dependencies and/or shared context; otherwise field preloads are generally preferable for localizing dependencies and blocking as little eager discovery as possible.

**Preload keys**

The `preload` method does not require loader keys and will use the scope or field's resolved objects as keys by default. You can also manually pass keys, which is useful when chaining:

```ruby
class WidgetResolver < GraphQL::Breadth::FieldResolver
  def plan(exec_field, context)
    exec_field
       # uses the field's resolved objects as keys...
      .preload(AssociationPreload, args: { association: :sprockets })
      .then do |sprockets|
        exec_field
          # manually passes preloaded sprockets as keys...
          .preload(AssociationPreload, args: { association: :prices }, keys: sprockets)
      end
  end
end
```

### Preloads hooks

Some lazy preloads may need to be configured at the time of execution when objects are actually avaiable for a scope or field. The `on_preload` hook may be used during planning to configure preloads in a just-in-time manner.

```ruby
class WidgetResolver < GraphQL::Breadth::FieldResolver
  def plan(exec_field, context)
    exec_field.on_preload do
      widgets = exec_field.objects.grep(Widget)
      exec_field.preload(AssociationLoader, keys: widgets, args: { association: :prices })
    end
  end
end
```

### Planning root

It's useful to use the root scope as a preload target where all fields in the document can pool common work (ex: loading auth dependencies into a context cache). However –  abstract selection branches are planned _lazily after resolution_, at which time the document above their subtree has been sealed and no longer accepts preloads. Use `planning_root` to always locate the highest unplanned scope and operate there:

```ruby
class WidgetResolver < GraphQL::Breadth::FieldResolver
  def plan(exec_field, context)
    exec_field.scope.planning_root.preload(AuthContextLoader, keys: [context[:agent].id])
  end
end
```

While navigating up the execution tree, you may call `allows_preload?` on scopes and fields to check their status. This check always returns false for taxonomy above the current `planning_root`.

### Attribute annotations

It can be useful to make notes about the execution tree while planning. Both execution scopes and fields provide an `attributes` hash for freeform annotations:

```ruby
class WidgetResolver < GraphQL::Breadth::FieldResolver
  def plan(exec_field, context)
    ancestor_scope = exec_field.scope&.parent
    if ancestor_scope && ancestor_scope.parent_type == Sprocket
      ancestor_scope.attributes[:include_widgets_sql] = true
    end
  end
end
```

Once tree annotations are set during the planning phase, field resolvers can respond accordingly to their notes while executing. When reading attributes, prefer using `element.attribute(key)` to avoid allocating unnecessary storage.

## Authorization

The breadth executor includes a authorization model that can be customized as needed. Create a `GraphQL::Breadth::Authorization` subclass and pass it to your executor:

```ruby
class MyAuthorization < GraphQL::Breadth::Authorization
  # ... detail auth behaviors
end

GraphQL::Breadth::Executor.new(
  MyGraphQLSchema,
  GraphQL.parse(document),
  authorization: MyAuthorization,
)
```

Authorization gates access at three grains: permission to access types, permission to access fields, and permission to access resolved objects. These grains are configured with the following authorization method implementations:

* `authorized_type?(type, context, exec_field: nil)`: checks if a type may be accessed before entering a scope of the type, and before executing a field that returns the type.
* `authorized_field?(exec_field, context)`: checks if a field may be accessed before executing its resolver. This should _only_ check if the field itself is authorized; it should NOT consider the field's owner type and/or return type, which are both covered by direct type checks (see above).
* `authorize_objects_in_scope?(exec_scope, context)`: checks if object-level authorization checks should run in this scope.
* `unauthorized_object_indices(exec_scope, context)`: checks authorization on all scope objects, and returns an invalidation map formatted as `Hash[Integer, StandardError?]`. The returned hash maps object indicies to their corresponding authorization errors. An empty hash means no objects were invalidated.

## Runtime directives

Breadth execution supports runtime directive behaviors applied to the `QUERY | MUTATION | FIELD` locations. While a schema may define runtime directives in other document locations, these are for AST reference only and provide no execution hooks.

**This is an operation-level directive (`QUERY | MUTATION` locations):**

```graphql
query @inContext(lang: EN) {
  myField
}
```

**These are field-level directives (`FIELD` location):**

```graphql
query {
  thing @language(lang: EN) {
    title
    child @language(lang: FR) {
      title
    }
  }
}
```

To implement a runtime directive, set up a `Breadth::DirectiveResolver` and assign it to the directive class:

```ruby
class LanguageDirectiveResolver < DirectiveResolver
  def resolve(exec_directive, context, current_field: nil)
    return if current_field.nil?

    current_field.attribute[:lang] = exec_directive.arguments[:lang]
  end
end

class Language < GraphQL::Schema::Directive
  extend GraphQL::Breadth::HasBreadthResolver::Directive

  graphql_name("language")
  argument :lang, String, required: true
  locations QUERY, MUTATION, FIELD

  self.breadth_resolver = LanguageDirectiveResolver.new
end
```

You can also install directive resolvers via a resolver map:

```ruby
RESOLVER_MAP = {
  "@language" => LanguageDirectiveResolver.new,
  "Query" => {
    "widgets" => WidgetsFieldResolver.new,
  },
}
```

### Wrapping directives

Directive resolvers can be configured as block wrappers around all of GraphQL execution (QUERY / MUTATION), or around the execution of a field (FIELD). Wrapping is disabled by default because it adds overhead. To enable wrapping for a specific directive, enable it for the resolver and include a `yield` in its resolver, or pass the resolver `&block` forward:

```ruby
class InContextDirectiveResolver < DirectiveResolver
  def initialize
    super(wraps: true)
  end

  def resolve(exec_directive, context, current_field: nil, &block)
    MyI18N.with_context(exec_directive.arguments[:lang], &block) # << must yield
  end
end
```

**Return note:** wrapping directives must return their block result; non-wrapping directives have no return expectations.

**Lazy loading note:** fields are only wrapped by directives during their primary execution pass. If a wrapped field defers to a lazy loader, it must pass any directive state as an argument to the loader. This both preserves the state and assures the field doesn't batch with other fields of different state. Wrapping at the root operation level assigns global execution state that is consistent across both eager and lazy field executions.

### Cascading directives

Breadth execution runs field resolvers via flat queuing rather than recursively, which changes conventional expectations around tree nesting slightly. Consider this example:

```graphql
query {
  a @language(lang: EN) {
    title
    b {
      title
    }
    c @language(lang: FR) {
      title
    }
  }
}
```

We expect `a` to assign a base language of `EN` that `b` inherits, and then `c` overrides with a more specific setting. Breadth execution achieves this by marking directives as _cascading_. A cascading directive will be passed down to all of its child fields within a stacking queue. A field execution then runs all directives that it inherited in the order they were queued, followed by any directives defined on the field itself.

```ruby
class LanguageDirectiveResolver < DirectiveResolver
  def initialize
    super(cascades: true)
  end

  def resolve(exec_directive, context, current_field: nil)
    return if current_field.nil?

    # repeatedly write each cascading directive's value onto the field; last one wins...
    current_field.attribute[:lang] = exec_directive.arguments[:lang]
  end
end
```

This architecture makes cascading resolvers run repeatedly on every field in a subtree, rather than just once at the top of the owning field's subtree. This pattern is more granular and generally safer for isolation and parallelism, though has more resolver churn than a typical depth traversal so should be used accordingly.

## Incremental results (`@defer` and `@stream`)

Query and mutation operations that may contain `@defer` or `@stream` should use `incremental_result`. This always returns a `GraphQL::Breadth::Incremental::Result`, even when the operation has no active incremental work:

```ruby
result = executor.incremental_result

deliver(result.initial_result)

if result.incremental?
  result.subsequent_results.each do |payload|
    deliver(payload)
  end
end
```

When no incremental work is active, `initial_result` is the normal GraphQL result hash and `incremental?` is false. Otherwise, `initial_result` includes pending records and `hasNext`, and `subsequent_results` yields later payloads.

`@stream` supports demand-driven sources as well as resolved Ruby arrays. A field resolver may implement a separate `stream` hook that is called only by `incremental_result` when the field has an active `@stream` directive. Ordinary `result` execution always calls `resolve` and never constructs a stream:

```ruby
class VariantNodesResolver < GraphQL::Breadth::FieldResolver
  def resolve(exec_field, _context)
    exec_field.map_objects { _1.load_all_variants }
  end

  def stream(exec_field, _context, initial_count:)
    # One cursor per breadth position. Each cursor yields an Array containing
    # the next useful chunk of raw records, then eventually stops.
    exec_field.objects.map do |connection|
      connection.variant_pages(page_size: [initial_count, 50].max)
    end
  end
end
```

The stream hook may return either:

* One `Enumerator` whose every yield is an outer array matching the field's breadth cardinality. Each position contains that cycle's array of records or `nil` when the position made no progress. This lets the resolver own batching across all parent objects.
* An array matching the field's breadth cardinality, containing one `Enumerator` per active position. Each enumerator yields arrays of records independently. A `nil` positional source resolves that list position as GraphQL `null`.

Use the explicit constructors when configuration or clarity is useful:

```ruby
GraphQL::Breadth::Incremental::Stream.collective(mapped_batches)

GraphQL::Breadth::Incremental::Stream.positional(
  per_connection_sources,
  async: true,
  resource: :variants_database,
  limit: 8,
  timeout: 2,
  throttle: VARIANT_API_THROTTLE,
)
```

Async positional pulls use the same fiber scheduler, resource semaphores, timeouts, and throttles as async lazy loaders. All eligible positions are advanced concurrently up to the configured limit, and the resulting records are then completed together through an isolated breadth fork. Source pulling and child execution are deliberately serialized so shared lazy-loader instances are never used concurrently.

A source normally completes by ending enumeration. It may mark its final chunk explicitly to avoid a completion-only follow-up payload:

```ruby
yielder << GraphQL::Breadth::Incremental::Stream.chunk(records, complete: true)
```

The executor pulls only enough source chunks to satisfy `initialCount` for every active breadth position. Chunk overflow is buffered for subsequent delivery; later pulls happen only as `subsequent_results` is consumed. If `stream` returns `nil`, the executor calls `resolve` and adapts its eager arrays into incremental delivery. This fallback matches synchronous iterable behavior but does not claim to stream record acquisition.

The stream hook may also return an `ExecutionPromise` from `exec_field.lazy`. This allows source discovery to use ordinary loaders before returning a collective or positional stream, including cases where discovery and streamed records have different resource limits or throttles.

For either source form, each produced chunk is completed through the normal breadth engine. Child fields and lazy loaders remain batched across all records in that cohort:

```graphql
query StreamProducts {
  products {
    nodes @stream(initialCount: 3, label: "products") {
      id
      title
    }
  }
}
```

Incremental execution is coordinated outside the normal query/mutation runner. Each deferred selection or produced stream cohort becomes work executed by an isolated fork that reuses the standard planner, field engine, authorization, lazy loaders, and error formatter. Ordinary `result` execution does not construct this subsystem and treats `@stream` as a normal complete list.

The basic and incremental entry points are intentionally strict. Call either `result` OR `incremental_result` for a query or mutation executor depending on the request's support for incremental delivery (ex: multi-part and SSE requests); switching entry points after execution has started raises an implementation error.

## Subscriptions

Query and mutation execution use `result`, which always returns a normal GraphQL result hash. Subscription operations use `subscribe`, which returns a `GraphQL::Breadth::SubscriptionResponseStream` on successful source setup, or a normal GraphQL result hash for public setup errors. Each entry point is strict about its operation type, matching the `execute` / `subscribe` split in graphql-js: calling `result` (or `incremental_result`) for a subscription operation raises an implementation error, and calling `subscribe` for a query or mutation operation raises an implementation error. A controller that accepts both inspects the operation type and dispatches accordingly:

```ruby
executor = GraphQL::Breadth::Executor.new(
  MyGraphQLSchema,
  GraphQL.parse(document),
  variables: { ... },
  context: { ... },
)

if executor.subscription?
  stream = executor.subscribe
  stream.each do |event_result|
    deliver(event_result)
  end
else
  deliver(executor.result)
end
```

Subscription root fields use two field resolver hooks:

* `subscribe(exec_field, context)` runs once during subscription setup and must return an `Enumerable` or `Enumerator` of source events.
* `resolve(exec_field, context)` runs once per yielded source event. The source event is used as the root object for that event's GraphQL execution.

```ruby
class OnWriteValueResolver < GraphQL::Breadth::FieldResolver
  def subscribe(exec_field, context)
    context[:write_value_events]
  end

  def resolve(exec_field, context)
    exec_field.map_objects(&:itself)
  end
end

class WriteValuePayload < BaseObject
  field :value, String, null: true
end

class Subscription < BaseObject
  field :on_write_value, WriteValuePayload, null: true do |field|
    field.breadth_resolver = OnWriteValueResolver.new
  end
end
```

For a small in-process source stream, any Ruby enumerator is enough:

```ruby
write_value_events = Enumerator.new do |events|
  events << { value: "first" }
  events << { value: "second" }
end

executor = GraphQL::Breadth::Executor.new(
  MyGraphQLSchema,
  GraphQL.parse(%|
    subscription WatchWrites {
      onWriteValue {
        value
      }
    }
  |),
  context: { write_value_events: write_value_events },
)

stream = executor.subscribe
stream.each do |event_result|
  # {"data"=>{"onWriteValue"=>{"value"=>"first"}}}
  # {"data"=>{"onWriteValue"=>{"value"=>"second"}}}
  deliver(event_result)
end
```

Each source event is fulfilled through normal breadth execution, so field resolvers, lazy loading, authorization, directives, abstract type resolution, and error formatting all work as they do for query execution. Errors raised while enumerating the source stream are allowed to propagate to the stream consumer. Promise-backed subscription setup is not supported; `subscribe` should return the source stream synchronously. Returning a promise or any non-enumerable value is an implementation error.
