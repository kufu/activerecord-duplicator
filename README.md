# activerecord-duplicator

Duplicate an ActiveRecord record together with its associated rows (has_many,
has_one, belongs_to, has_many :through) in one call. Foreign keys are rewired
through an internal id map; callbacks are bypassed via `insert_all!` so
duplication does not fire `after_create` and friends. Per-model handlers let
you plug in custom logic when a plain copy is not enough. Composite primary
keys (Rails 7.1+) are supported.

## Installation

```bash
bundle add activerecord-duplicator
```

Or without Bundler:

```bash
gem install activerecord-duplicator
```

## Requirements

- Ruby >= 3.3
- ActiveRecord >= 8.0 (tested against 8.0, 8.1)
- A database adapter whose connection reports
  `supports_insert_returning? == true`. The default duplication path uses
  `insert_all!` and needs the adapter to echo inserted primary keys back so
  the id map can be populated in a single round trip.
  - PostgreSQL (via `pg`): always supported.
  - SQLite (via `sqlite3`): SQLite >= 3.35 is required; the modern
    `sqlite3` gem ships a compatible native binary.
  - MySQL / Trilogy: not supported by the default path because those
    adapters do not implement RETURNING. Duplication of specific models can
    still be done through a custom handler registered with `Duplicator#on`
    (see below).

The gem does not depend on a specific adapter gem; applications add whichever
one they use (`pg`, `sqlite3`, ...) to their own Gemfile.

## Non-goals

### STI dispatch

This gem dispatches based on the class of the input Relation (or the first
element for Arrays). If your Relation mixes STI subclasses and you need
per-subclass handlers, split the input into per-subclass Relations before
passing them in. Ancestor-walking dispatch (register a handler on a base class,
have it fire for subclass records mixed in one Relation) is intentionally not
supported; see CHANGELOG for details.

## Usage

### Basic duplication

```ruby
duplicator = ActiveRecord::Duplicator.new

new_post = duplicator.duplicate(
  old_post,
  associations: [:comments, tags: :taggings],
)
```

`duplicate` creates a new `Post` (and all rows reachable via the given
`associations`), rewires every foreign key to point at the freshly created
parents, and returns the new root record.

### Keeping records referenced but not copied (`no_duplicate`)

When you want the duplicated rows to keep pointing at an existing record
(for example the current tenant, current user, or a shared lookup table),
call no_duplicate on that record before calling `duplicate`:

```ruby
duplicator = ActiveRecord::Duplicator.new
duplicator.no_duplicate(tenant)
duplicator.no_duplicate(current_user)

duplicator.duplicate(old_project, associations: [tasks: :attachments])
```

Skipped records get `new_id == old_id` in the internal map, so children that
reference them are inserted with the original id unchanged.

### Skipping a whole model (`no_duplicate_class`)

When every row of a model should be reused by id (a shared lookup table,
a tenant-wide catalog, an enum-backed table with dozens of entries), call no_duplicate_class
the class itself instead of enumerating rows. `no_duplicate_class` exists at
both scopes and mirrors `on`: register once on the Duplicator to inherit
across every run, or add it in the Session block for a single run.

```ruby
duplicator = ActiveRecord::Duplicator.new
duplicator.no_duplicate_class(Tag)           # applies to every subsequent run

duplicator.duplicate(old_post, associations: [:taggings])

duplicator.duplicate(other_post, associations: [:taggings]) do |session|
  session.no_duplicate_class(Currency)       # extra exclusion, this run only
end
```

Behaviour is exactly as if you had passed every row to `no_duplicate` up front:
handlers registered for the class still fire (so custom copy logic keeps
working), but the default `bulk_insert` path becomes a no-op and any
`fetch_duplicate_id(klass, old_id: ...)` from a child's foreign-key reassignment
echoes the old id back unchanged. `no_duplicate_class` only differs from
per-record `no_duplicate` in cost: no enumeration is needed to opt each row in.

### Skipping by id without loading records (`no_duplicate_id`)

When the ids are already known (a foreign key column, a prior
pluck, a config constant), use `no_duplicate_id` to register them directly
without issuing a `SELECT`:

```ruby
duplicator.duplicate(old_post, associations: [:taggings]) do |session|
  session.no_duplicate_id(Tag, 1, 2, 3)
end
```

For composite primary keys pass each id as an Array:

```ruby
session.no_duplicate_id(Item, [tenant_id, 10], [tenant_id, 11])
```

`no_duplicate_id` has the same effect as calling `no_duplicate` on the
corresponding records: `fetch_duplicate_id` returns the old id unchanged for
each registered id.

### Registering an id from outside (`store_duplicate_id` / `fetch_duplicate_id`)

If you produce a duplicate yourself (for example a model with a uniqueness
constraint that has to be reshaped before insert), tell the session about the
mapping so downstream children can find the new parent id:

```ruby
new_project = old_project.dup
new_project.slug = "#{old_project.slug}-copy"
new_project.save!

duplicator = ActiveRecord::Duplicator.new
duplicator.store_duplicate_id(Project, old_id: old_project.id, new_id: new_project.id)
duplicator.duplicate(old_project, associations: [:tasks])
```

`fetch_duplicate_id(klass, old_id:)` returns the mapping (scalar for a single-column
primary key, Array for a composite one) and raises `MissingNewIdError` if the
parent has not been duplicated yet.

### Per-model handlers (`on`)

Some models need custom logic that the default `insert_all!` path cannot
express: ActiveStorage attachments, unique constraint rewrites, values that
depend on the target tenant, and so on. Register a handler and it will be
called instead of the default duplication path for that class:

```ruby
duplicator.on(Attachment) do |api, klass, records|
  records.find_each do |record|
    new_record = klass.create!(
      post_id: api.fetch_duplicate_id(Post, old_id: record.post_id),
    )
    new_record.file.attach(record.file.blob)
    api.store_duplicate_id(klass, old_id: record.id, new_id: new_record.id)
  end
end
```

`api` is a `HandlerApi` facade over the session that exposes
`no_duplicate` / `store_duplicate_id` / `fetch_duplicate_id` / `bulk_insert` /
`attributes_for`. Registering two handlers for the same class raises
`DuplicateHandlerError`.

### Composite primary keys

`self.primary_key = [:tenant_id, :id]` classes are handled the same way.
Non-auto columns of the composite pk (e.g. `tenant_id`) are carried over from
the source record; only DB-populated columns (e.g. a `bigserial id`) get fresh
values. `foreign_key: [:tenant_id, :owner_id]` associations are traversed with
tuple `WHERE (a, b) IN ((v1, v2), ...)` syntax.

### Errors

All errors inherit from `ActiveRecord::Duplicator::Error`:

- `InvalidRecordIdError`: the same `old_id` was registered with a different `new_id`.
- `MissingNewIdError`: `fetch_duplicate_id` had no mapping. Usually means a
  belongs_to parent was not duplicated yet; place it earlier in the
  associations tree, or call no_duplicate / no_duplicate_id on it.
- `DuplicateHandlerError`: `on(klass)` was called twice for the same class.
- `UnsupportedAdapterError`: the default `bulk_insert` was invoked against a
  connection whose adapter does not implement `supports_insert_returning?`
  (for example mysql2 or trilogy). Register a handler with
  `Duplicator#on` / `Session#on` that uses `create!` (or another
  RETURNING-free path) for that model.

Because they share a common ancestor, one `rescue` clause catches any
duplication-specific failure:

```ruby
begin
  duplicator.duplicate(old_post, associations: [:comments])
rescue ActiveRecord::Duplicator::Error => e
  Rails.logger.error("duplication failed: #{e.class.name} #{e.message}")
  raise
end
```

### Performance notes

`AssociationTraversal` currently pluck-collects parent ids and emits
`WHERE fk IN (id1, ..., idN)`. Very large N (tens of thousands) may hit
PostgreSQL planner degradation; if you run into this, split your work into
smaller root records or file an issue.

## Development

The gem tests against a real database. `compose.yml` at the repo root starts a
PostgreSQL instance for you on port 55432:

```bash
docker compose up -d

bundle install
bundle exec rake       # rspec + rubocop
bundle exec rspec      # spec only
```

Switch adapters with `ARCONN`; SQLite runs against an in-memory database and
needs no external service:

```bash
ARCONN=postgresql bundle exec rspec   # default (uses DATABASE_URL)
ARCONN=sqlite3    bundle exec rspec
```

Override the PostgreSQL connection with `DATABASE_URL` (used by CI):

```bash
DATABASE_URL=postgres://user:pass@host:port/db bundle exec rspec
```

Both adapters are exercised in CI on every push and pull request.

## Contributing

Bug reports and pull requests are welcome on GitHub at
<https://github.com/kufu/activerecord-duplicator>. Please read
[CONTRIBUTION.md](CONTRIBUTION.md) for how to report bugs, submit patches,
and disclose security issues. This project is intended to be a safe,
welcoming space for collaboration; contributors are expected to adhere to
the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Released under the [Apache License, Version 2.0](LICENSE.md).
