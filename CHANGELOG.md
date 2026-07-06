## [Unreleased]

## [0.2.0] - 2026-07-06

- Drop support for Ruby 3.2 (EOL)
- Drop support for Rails 7.2; assume ActiveRecord >= 8.0 so `in_batches(cursor:)` is always available

### Removed (breaking)

- STI (Single Table Inheritance) dispatch in `Session#duplicate_records`.
  Handlers are now looked up by the input Relation's `klass` (or the first
  element's class for Arrays), with no ancestor walk and no `group_by(&:class)`.
  If you were relying on registering a handler on a base class and expecting
  it to fire for subclass records mixed in one Relation, split your input by
  subclass and register handlers on each concrete class instead.

### Changed (breaking)

- Handlers now receive an `ActiveRecord::Relation` (not an Array) when the
  input to duplication was a Relation. This lets `api.bulk_insert(klass,
  records, cursor: [...])` take the `in_batches(cursor:)` path and enables
  cursor-based keyset pagination for large child sets.
- Default (handler-less) dispatch of a Relation now uses `find_in_batches`
  internally, reducing peak memory for large child sets.

### Migration

- Handlers that previously used Array-only methods (`records.reject!`, etc.)
  on the third argument must convert to Array explicitly:
  `records = records.to_a`.

## [0.1.0] - 2026-07-02

- Add `ActiveRecord::Duplicator::AssociationTraversal` — breadth-first traversal of preload-style association specifications
- Add `ActiveRecord::Duplicator::Session` — coordinates one duplication run: record id map, handler registry, `duplicate` / `bulk_insert` / `attributes_for`
- Add `ActiveRecord::Duplicator::HandlerApi` — facade passed to `Session#on` handler blocks
- Add error types under `ActiveRecord::Duplicator::Error`: `InvalidRecordIdError` / `MissingNewIdError` / `DuplicateHandlerError`
- Support composite primary keys (Rails 7.1+)
