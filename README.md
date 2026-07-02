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

- Ruby >= 3.2
- ActiveRecord >= 7.1
- PostgreSQL (via `pg` gem). The gem relies on `insert_all!` returning inserted
  primary keys.

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

### Keeping records referenced but not copied (`mark_skip`)

When you want the duplicated rows to keep pointing at an existing record
(for example the current tenant, current user, or a shared lookup table),
mark that record as skipped before calling `duplicate`:

```ruby
duplicator = ActiveRecord::Duplicator.new
duplicator.mark_skip(tenant)
duplicator.mark_skip(current_user)

duplicator.duplicate(old_project, associations: [tasks: :attachments])
```

Skipped records get `new_id == old_id` in the internal map, so children that
reference them are inserted with the original id unchanged.

### Registering an id from outside (`store_new_id` / `fetch_new_id`)

If you produce a duplicate yourself (for example a model with a uniqueness
constraint that has to be reshaped before insert), tell the session about the
mapping so downstream children can find the new parent id:

```ruby
new_project = old_project.dup
new_project.slug = "#{old_project.slug}-copy"
new_project.save!

duplicator = ActiveRecord::Duplicator.new
duplicator.store_new_id(Project, old_id: old_project.id, new_id: new_project.id)
duplicator.duplicate(old_project, associations: [:tasks])
```

`fetch_new_id(klass, old_id:)` returns the mapping (scalar for a single-column
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
      post_id: api.fetch_new_id(Post, old_id: record.post_id),
    )
    new_record.file.attach(record.file.blob)
    api.store_new_id(klass, old_id: record.id, new_id: new_record.id)
  end
end
```

`api` is a `HandlerApi` facade over the session that exposes
`mark_skip` / `store_new_id` / `fetch_new_id` / `bulk_insert` /
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

- `InvalidRecordIdError` — the same `old_id` was registered with a different `new_id`.
- `MissingNewIdError` — `fetch_new_id` had no mapping. Usually means a
  belongs_to parent was not duplicated yet; place it earlier in the
  associations tree or mark it skipped.
- `DuplicateHandlerError` — `on(klass)` was called twice for the same class.

### Performance notes

`AssociationTraversal` currently pluck-collects parent ids and emits
`WHERE fk IN (id1, ..., idN)`. Very large N (tens of thousands) may hit
PostgreSQL planner degradation; if you run into this, split your work into
smaller root records or file an issue.

## Development

The gem tests against a real PostgreSQL instance. `compose.yml` at the repo
root starts one for you on port 15432:

```bash
docker compose up -d

bundle install
bundle exec rake       # rspec + rubocop
bundle exec rspec      # spec only
```

Override the connection with `DATABASE_URL` (used by CI):

```bash
DATABASE_URL=postgres://user:pass@host:port/db bundle exec rspec
```

## Contributing

Bug reports and pull requests are welcome on GitHub at
<https://github.com/alpaca-tc/activerecord-duplicator>. This project is
intended to be a safe, welcoming space for collaboration; contributors are
expected to adhere to the [code of conduct](CODE_OF_CONDUCT.md).

## License

Released under the [MIT License](https://opensource.org/licenses/MIT).
