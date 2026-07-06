## [Unreleased]

- Drop support for Ruby 3.2 (EOL)
- Drop support for Rails 7.2; assume ActiveRecord >= 8.0 so `in_batches(cursor:)` is always available

## [0.1.0] - 2026-07-02

- Add `ActiveRecord::Duplicator::AssociationTraversal` — breadth-first traversal of preload-style association specifications
- Add `ActiveRecord::Duplicator::Session` — coordinates one duplication run: record id map, handler registry, `duplicate` / `bulk_insert` / `attributes_for`
- Add `ActiveRecord::Duplicator::HandlerApi` — facade passed to `Session#on` handler blocks
- Add error types under `ActiveRecord::Duplicator::Error`: `InvalidRecordIdError` / `MissingNewIdError` / `DuplicateHandlerError`
- Support composite primary keys (Rails 7.1+)
