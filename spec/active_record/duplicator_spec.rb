# frozen_string_literal: true

RSpec.describe ActiveRecord::Duplicator do
  isolated_schema "duplicator_spec" do |schema|
    schema.create_table :owners do |t|
      t.string :name
      t.timestamps
    end
    schema.create_table :items do |t|
      t.bigint :owner_id
      t.string :label
      t.timestamps
    end
    schema.create_table :profiles do |t|
      t.bigint :owner_id
      t.string :bio
      t.timestamps
    end
    schema.create_table :tags do |t|
      t.string :name
      t.timestamps
    end
    schema.create_table :item_taggings do |t|
      t.bigint :item_id
      t.bigint :tag_id
      t.timestamps
    end
    schema.create_table :composite_owners, primary_key: %i[tenant_id id] do |t|
      t.bigint :tenant_id, null: false
      t.column :id, :bigserial, null: false
      t.string :name
    end
    schema.create_table :composite_items, primary_key: %i[tenant_id id] do |t|
      t.bigint :tenant_id, null: false
      t.column :id, :bigserial, null: false
      t.bigint :owner_id, null: false
      t.string :label
    end
    schema.create_table :legacy_ts_items do |t|
      t.string :label
      t.datetime :created_on
      t.datetime :updated_on
    end
  end

  describe "VERSION" do
    it "is a non-nil string" do
      expect(ActiveRecord::Duplicator::VERSION).to be_a(String)
    end
  end

  describe ".new" do
    it "returns a Duplicator instance (reusable per-handler registration)" do
      duplicator = described_class.new
      expect(duplicator).to be_a(described_class)
    end
  end

  describe "#on" do
    it "invokes the registered handler instead of the default bulk_insert" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
      end)

      original = Owner.create!(name: "o")
      original.items.create!(label: "raw")

      duplicator = described_class.new
      duplicator.on(Item) do |api, klass, records|
        records.each do |record|
          new_item = klass.create!(
            owner_id: api.fetch_duplicate_id(Owner, old_id: record.owner_id),
            label: "handled_#{record.label}",
          )
          api.store_duplicate_id(klass, old_id: record.id, new_id: new_item.id)
        end
      end

      new_owner = duplicator.duplicate(original, associations: [:items])

      expect(new_owner.items.count).to eq(1)
      expect(new_owner.items.first.label).to eq("handled_raw")
    end

    it "exposes bulk_insert on HandlerApi so handlers can defer to the default path" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
      end)

      original = Owner.create!(name: "o")
      original.items.create!(label: "i1")
      original.items.create!(label: "i2")

      duplicator = described_class.new
      handler_called = false
      duplicator.on(Item) do |api, klass, records|
        handler_called = true
        api.bulk_insert(klass, records)
      end

      new_owner = duplicator.duplicate(original, associations: [:items])

      expect(handler_called).to be true
      expect(new_owner.items.count).to eq(2)
      expect(new_owner.items.map(&:label)).to match_array(%w[i1 i2])
    end

    it "raises DuplicateHandlerError when the same class is registered twice" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      duplicator = described_class.new
      duplicator.on(Owner) { |_api, _klass, _records| }

      expect { duplicator.on(Owner) { |_api, _klass, _records| } }
        .to raise_error(ActiveRecord::Duplicator::DuplicateHandlerError)
    end
  end

  describe "#no_duplicate_class" do
    it "applies the skip to every subsequent duplicate call from the same Duplicator" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
        has_many :item_taggings, through: :items, class_name: "ItemTagging"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
        has_many :item_taggings, class_name: "ItemTagging"
      end)
      stub_const("Tag", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.tags"
      end)
      stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.item_taggings"
        belongs_to :item, class_name: "Item"
        belongs_to :tag, class_name: "Tag"
      end)

      tag = Tag.create!(name: "t")
      owner_a = Owner.create!(name: "a")
      ItemTagging.create!(item: owner_a.items.create!(label: "ia"), tag:)
      owner_b = Owner.create!(name: "b")
      ItemTagging.create!(item: owner_b.items.create!(label: "ib"), tag:)

      # Register the skip once on the Duplicator; both runs must inherit it.
      duplicator = described_class.new
      duplicator.no_duplicate_class(Tag)

      tag_count_before = Tag.count
      new_a = duplicator.duplicate(owner_a, associations: [items: :item_taggings, item_taggings: :tag])
      new_b = duplicator.duplicate(owner_b, associations: [items: :item_taggings, item_taggings: :tag])

      expect(Tag.count).to eq(tag_count_before)
      expect(new_a.item_taggings.pluck(:tag_id).uniq).to eq([tag.id])
      expect(new_b.item_taggings.pluck(:tag_id).uniq).to eq([tag.id])
    end

    it "is idempotent when the same class is marked twice" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      duplicator = described_class.new
      duplicator.no_duplicate_class(Owner)

      expect { duplicator.no_duplicate_class(Owner) }.not_to raise_error
    end

    it "does not leak Session#no_duplicate_class additions back to the Duplicator" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)
      stub_const("Tag", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.tags"
      end)

      # A second run without a session block must not inherit Tag's skip.
      # If it did, the second run would echo back a nonexistent tag id when
      # fetch_duplicate_id was queried — but here we verify indirectly: the second
      # run's Owner root is duplicated (no_duplicate_class on Owner would return
      # the original) and the id differs from the original.
      original = Owner.create!(name: "o")
      duplicator = described_class.new

      duplicator.duplicate(original) do |session|
        session.no_duplicate_class(Owner)
      end

      new_owner = duplicator.duplicate(original)
      expect(new_owner.id).not_to eq(original.id)
    end
  end

  describe "#freeze" do
    it "prevents further handler registration after freeze" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      duplicator = described_class.new
      duplicator.freeze

      expect { duplicator.on(Owner) { |_api, _klass, _records| } }
        .to raise_error(FrozenError)
    end

    it "prevents further no_duplicate_class after freeze" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      duplicator = described_class.new
      duplicator.freeze

      expect { duplicator.no_duplicate_class(Owner) }
        .to raise_error(FrozenError)
    end

    it "still lets duplicate produce independent sessions after freeze" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      original1 = Owner.create!(name: "a")
      original2 = Owner.create!(name: "b")

      duplicator = described_class.new
      duplicator.freeze

      new_owner1 = duplicator.duplicate(original1)
      new_owner2 = duplicator.duplicate(original2)

      expect(new_owner1.name).to eq("a")
      expect(new_owner2.name).to eq("b")
      # separate Sessions were used: their ids don't collide
      expect(new_owner1.id).not_to eq(new_owner2.id)
    end
  end

  describe "#duplicate" do
    it "duplicates a single record with no associations" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      original = Owner.create!(name: "o")

      new_owner = described_class.new.duplicate(original)

      expect(new_owner).to be_a(Owner)
      expect(new_owner.id).not_to eq(original.id)
      expect(new_owner.name).to eq("o")
    end

    it "invokes root_record.transaction with no options when transaction_options is omitted" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)
      original = Owner.create!(name: "o")

      # Duplicator#duplicate must plumb through to Session#run's default,
      # i.e. plain `transaction do ... end` with no keyword args.
      expect(original).to receive(:transaction).with(no_args).and_call_original

      described_class.new.duplicate(original)
    end

    it "forwards transaction_options through Session#run to root_record.transaction" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)
      original = Owner.create!(name: "o")

      # Verifies the full plumbing: Duplicator#duplicate -> Session#run ->
      # root_record.transaction receives the hash verbatim.
      expect(original)
        .to receive(:transaction)
        .with(requires_new: true, joinable: false)
        .and_call_original

      described_class.new.duplicate(original, transaction_options: { requires_new: true, joinable: false })
    end

    it "rewires has_many foreign keys to the new parent" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
      end)

      original = Owner.create!(name: "o")
      original.items.create!(label: "i1")
      original.items.create!(label: "i2")

      new_owner = described_class.new.duplicate(original, associations: [:items])

      expect(new_owner.items.count).to eq(2)
      expect(new_owner.items.map(&:label)).to match_array(%w[i1 i2])
      expect(new_owner.items.map(&:owner_id).uniq).to eq([new_owner.id])
    end

    it "yields a fresh Session to the block so the caller can no_duplicate parents" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
        has_many :item_taggings, class_name: "ItemTagging"
      end)
      stub_const("Tag", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.tags"
      end)
      stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.item_taggings"
        belongs_to :item, class_name: "Item"
        belongs_to :tag, class_name: "Tag"
      end)

      tag = Tag.create!(name: "t")
      original = Owner.create!(name: "o")
      item = original.items.create!(label: "i")
      ItemTagging.create!(item:, tag:)

      duplicator = described_class.new
      new_owner = duplicator.duplicate(original, associations: [items: :item_taggings]) do |session|
        session.no_duplicate(tag)
      end

      expect(new_owner.items.count).to eq(1)
      new_item = new_owner.items.first
      expect(new_item.label).to eq("i")
      expect(new_item.item_taggings.count).to eq(1)
      # Tag was skipped, so the tagging still references the original tag id
      expect(new_item.item_taggings.first.tag_id).to eq(tag.id)
    end

    it "starts each call with a fresh id map (no state leaked between runs)" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      original = Owner.create!(name: "o")

      duplicator = described_class.new
      # Two independent runs on the same source record must both succeed;
      # if the id map were shared, the second run would either short-circuit
      # or raise InvalidRecordIdError on the root.
      new_owner1 = duplicator.duplicate(original)
      new_owner2 = duplicator.duplicate(original)

      expect(new_owner1.id).not_to eq(original.id)
      expect(new_owner2.id).not_to eq(original.id)
      expect(new_owner1.id).not_to eq(new_owner2.id)
    end

    it "returns the original record itself when the root is marked as skipped" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      original = Owner.create!(name: "o")

      result = described_class.new.duplicate(original) do |session|
        session.no_duplicate(original)
      end

      expect(result.id).to eq(original.id)
    end

    it "keeps children pointing at the original rows when no_duplicate_id skips specific ids" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
        has_many :item_taggings, through: :items, class_name: "ItemTagging"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
        has_many :item_taggings, class_name: "ItemTagging"
      end)
      stub_const("Tag", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.tags"
      end)
      stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.item_taggings"
        belongs_to :item, class_name: "Item"
        belongs_to :tag, class_name: "Tag"
      end)

      tag = Tag.create!(name: "t")
      original = Owner.create!(name: "o")
      item = original.items.create!(label: "i")
      ItemTagging.create!(item:, tag:)

      tag_count_before = Tag.count
      new_owner = described_class.new.duplicate(
        original,
        associations: [items: :item_taggings, item_taggings: :tag],
      ) do |session|
        # Skip by id — no Tag record is loaded, just the id is registered.
        session.no_duplicate_id(Tag, tag.id)
      end

      expect(Tag.count).to eq(tag_count_before)
      expect(new_owner.item_taggings.pluck(:tag_id)).to eq([tag.id])
    end

    it "keeps children pointing at the original rows when no_duplicate_class opts a whole model out" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
        has_many :item_taggings, through: :items, class_name: "ItemTagging"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
        has_many :item_taggings, class_name: "ItemTagging"
      end)
      stub_const("Tag", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.tags"
      end)
      stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.item_taggings"
        belongs_to :item, class_name: "Item"
        belongs_to :tag, class_name: "Tag"
      end)

      # Two pre-existing Tag rows shared across the app; the duplication run
      # should reuse them by id rather than inserting fresh copies.
      tag_a = Tag.create!(name: "a")
      tag_b = Tag.create!(name: "b")
      original = Owner.create!(name: "o")
      item = original.items.create!(label: "i")
      ItemTagging.create!(item:, tag: tag_a)
      ItemTagging.create!(item:, tag: tag_b)

      tag_row_count_before = Tag.count
      new_owner = described_class.new.duplicate(
        original,
        associations: [items: :item_taggings, item_taggings: :tag],
      ) do |session|
        session.no_duplicate_class(Tag)
      end

      # No new Tag row inserted — the class-level skip suppresses the
      # bulk_insert entirely.
      expect(Tag.count).to eq(tag_row_count_before)
      # New taggings still reference the original tag ids because
      # fetch_duplicate_id(Tag, ...) echoes old_id back for a skipped class.
      expect(new_owner.item_taggings.pluck(:tag_id))
        .to match_array([tag_a.id, tag_b.id])
    end

    it "still fires the handler for a skipped class (default bulk_insert is what no-ops)" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
        has_many :item_taggings, through: :items, class_name: "ItemTagging"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
        has_many :item_taggings, class_name: "ItemTagging"
      end)
      stub_const("Tag", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.tags"
      end)
      stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.item_taggings"
        belongs_to :item, class_name: "Item"
        belongs_to :tag, class_name: "Tag"
      end)

      tag = Tag.create!(name: "t")
      original = Owner.create!(name: "o")
      ItemTagging.create!(item: original.items.create!(label: "i"), tag:)

      handler_records = nil
      duplicator = described_class.new
      duplicator.on(Tag) do |api, klass, records|
        # A handler must still see the incoming records — no_duplicate_class is
        # advisory to bulk_insert, not to dispatch. Behaviour parity with
        # calling no_duplicate(*records) on every tag beforehand.
        handler_records = records.to_a
        api.bulk_insert(klass, records)
      end
      duplicator.no_duplicate_class(Tag)

      tag_row_count_before = Tag.count
      new_owner = duplicator.duplicate(
        original,
        associations: [items: :item_taggings, item_taggings: :tag],
      )

      expect(handler_records.map(&:id)).to eq([tag.id])
      # bulk_insert was called from the handler but short-circuited on the
      # skipped class, so no new Tag row appeared.
      expect(Tag.count).to eq(tag_row_count_before)
      expect(new_owner.item_taggings.pluck(:tag_id)).to eq([tag.id])
    end

    it "returns the original record itself when the root's class is marked as skipped" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      original = Owner.create!(name: "o")

      result = described_class.new.duplicate(original) do |session|
        session.no_duplicate_class(Owner)
      end

      # duplicate_records early-returns for Owner, no Owner row is inserted,
      # and Session#run falls back to fetch_duplicate_id -> old_id -> the original.
      expect(result.id).to eq(original.id)
    end

    it "lets Session#on override a Duplicator-level handler for the current run only" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
      end)

      original = Owner.create!(name: "o")
      original.items.create!(label: "raw")

      duplicator = described_class.new
      duplicator.on(Item) do |api, klass, records|
        records.each do |record|
          new_item = klass.create!(
            owner_id: api.fetch_duplicate_id(Owner, old_id: record.owner_id),
            label: "global_#{record.label}",
          )
          api.store_duplicate_id(klass, old_id: record.id, new_id: new_item.id)
        end
      end

      overridden = duplicator.duplicate(original, associations: [:items]) do |session|
        session.on(Item) do |api, klass, records|
          records.each do |record|
            new_item = klass.create!(
              owner_id: api.fetch_duplicate_id(Owner, old_id: record.owner_id),
              label: "session_#{record.label}",
            )
            api.store_duplicate_id(klass, old_id: record.id, new_id: new_item.id)
          end
        end
      end

      # A second run has no session-local override, so the global handler runs.
      default_run = duplicator.duplicate(original, associations: [:items])

      expect(overridden.items.first.label).to eq("session_raw")
      expect(default_run.items.first.label).to eq("global_raw")
    end

    it "does not invoke ActiveRecord callbacks on the duplicated records" do
      invoked = []

      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)
      Owner.after_create { invoked << name }

      original = Owner.create!(name: "o")
      expect(invoked).to eq(["o"]) # callback fires for the original create!

      invoked.clear
      new_owner = described_class.new.duplicate(original)

      # bulk_insert (insert_all!) must not trigger any callback
      expect(invoked).to be_empty
      # Duplication still produced a new row
      expect(new_owner.name).to eq("o")
      expect(new_owner.id).not_to eq(original.id)
    end
  end

  describe "with legacy created_on/updated_on timestamp columns" do
    it "strips created_on/updated_on so they are not carried over to the copy" do
      stub_const("LegacyTsItem", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.legacy_ts_items"
      end)

      original = LegacyTsItem.create!(
        label: "l",
        created_on: Time.utc(2020, 1, 1),
        updated_on: Time.utc(2020, 6, 1),
      )

      new_record = described_class.new.duplicate(original)

      expect(new_record.label).to eq("l")
      # klass.all_timestamp_attributes_in_model reports created_on/updated_on
      # for tables that use the legacy on-suffixed names, so those columns are
      # stripped from insert_all! attributes. insert_all! then repopulates
      # them via ActiveRecord's timestamp handling, so the new record never
      # inherits the source record's timestamp values.
      expect(new_record.created_on).not_to eq(original.created_on)
      expect(new_record.updated_on).not_to eq(original.updated_on)
    end
  end

  describe "handler dispatch by input class" do
    it "passes the input Relation through to the handler unchanged" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
      end)

      original = Owner.create!(name: "o")
      original.items.create!(label: "i1")
      original.items.create!(label: "i2")

      received_class = nil
      duplicator = described_class.new
      duplicator.on(Item) do |api, klass, records|
        received_class = records.class
        api.bulk_insert(klass, records)
      end

      duplicator.duplicate(original, associations: [:items])

      # AssociationTraversal yields ActiveRecord::Relation; without the old
      # `group_by(&:class)`, the Relation reaches the handler intact so a
      # handler can call `records.in_batches(cursor:)` etc.
      expect(received_class.ancestors).to include(ActiveRecord::Relation)
    end

    it "streams a Relation through find_in_batches on the default (handler-less) path" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
      end)

      original = Owner.create!(name: "o")
      3.times { |i| original.items.create!(label: "i#{i}") }

      # Force a small batch size so the streaming SELECT is issued more than
      # once; without STI dispatch the Relation reaches bulk_insert whole and
      # takes the `find_in_batches` branch in enumerate_batches.
      stub_const("ActiveRecord::Duplicator::Session::DEFAULT_BATCH_SIZE", 2)

      select_sqls = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql]
        select_sqls << sql if sql.start_with?("SELECT") && sql.include?(%("duplicator_spec"."items"))
      end

      begin
        described_class.new.duplicate(original, associations: [:items])
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end

      # find_in_batches issues at least two LIMIT-ed SELECTs when the row count
      # exceeds the batch size.
      limited = select_sqls.count { |sql| sql.include?("LIMIT") }
      expect(limited).to be >= 2
    end

    it "lets a handler take the cursor-based in_batches path via HandlerApi#bulk_insert" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
      end)

      original = Owner.create!(name: "o")
      3.times { |i| original.items.create!(label: "i#{i}") }

      duplicator = described_class.new
      duplicator.on(Item) do |api, klass, records|
        # With the old STI dispatch, `records` was always an Array and this
        # would silently fall back to each_slice; now it is a Relation, so
        # in_batches(cursor:) drives keyset pagination.
        api.bulk_insert(klass, records, batch_size: 2, cursor: [:id])
      end

      new_owner = duplicator.duplicate(original, associations: [:items])

      expect(new_owner.items.count).to eq(3)
      expect(new_owner.items.map(&:label)).to match_array(%w[i0 i1 i2])
    end

    it "hands an Array to the handler when the input to duplication is an Array" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      original = Owner.create!(name: "o")

      # The root record is always passed as a single-element Array by
      # Session#run, so on(Owner) sees an Array (not a Relation).
      received_class = nil
      duplicator = described_class.new
      duplicator.on(Owner) do |api, klass, records|
        received_class = records.class
        api.bulk_insert(klass, records)
      end

      duplicator.duplicate(original)

      expect(received_class).to eq(Array)
    end

    it "does not crash when a has_many association is empty" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.items"
        belongs_to :owner, class_name: "Owner"
      end)

      original = Owner.create!(name: "o")

      # An empty has_many yields an empty Relation into duplicate_records,
      # which must reach the handler / bulk_insert path without exploding
      # (both are Enumerable-safe against empty inputs).
      expect { described_class.new.duplicate(original, associations: [:items]) }.not_to raise_error
    end
  end

  describe "with composite primary key" do
    it "duplicates a single record with a composite primary key" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.composite_owners"
        self.primary_key = %i[tenant_id id]
      end)

      original = Owner.create!(tenant_id: 1, name: "o")

      new_owner = described_class.new.duplicate(original)

      expect(new_owner).to be_a(Owner)
      # tenant_id is a non-auto pk column, so it carries over unchanged
      expect(new_owner.tenant_id).to eq(1)
      # id is BIGSERIAL, so a fresh value is assigned (record[:id] reads the raw
      # column value; #id returns the composite tuple on Rails 7.1+ composite pk)
      expect(new_owner[:id]).not_to eq(original[:id])
      expect(new_owner.name).to eq("o")
    end

    it "preserves the original composite id when the record is marked as skipped" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.composite_owners"
        self.primary_key = %i[tenant_id id]
      end)

      original = Owner.create!(tenant_id: 1, name: "o")

      result = described_class.new.duplicate(original) do |session|
        session.no_duplicate(original)
      end

      expect(result.tenant_id).to eq(original.tenant_id)
      expect(result[:id]).to eq(original[:id])
    end

    it "duplicates has_many children when the association uses a composite foreign key" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.composite_owners"
        self.primary_key = %i[tenant_id id]
        has_many :items,
          class_name: "Item",
          foreign_key: %i[tenant_id owner_id],
          primary_key: %i[tenant_id id]
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.composite_items"
        self.primary_key = %i[tenant_id id]
        belongs_to :owner,
          class_name: "Owner",
          foreign_key: %i[tenant_id owner_id],
          primary_key: %i[tenant_id id]
      end)

      original = Owner.create!(tenant_id: 1, name: "o")
      Item.create!(tenant_id: 1, owner_id: original[:id], label: "i1")
      Item.create!(tenant_id: 1, owner_id: original[:id], label: "i2")

      new_owner = described_class.new.duplicate(original, associations: [:items])

      expect(new_owner.items.count).to eq(2)
      expect(new_owner.items.map(&:label)).to match_array(%w[i1 i2])
      # foreign key is composite: both tenant_id and owner_id should point to the new owner
      expect(new_owner.items.map(&:tenant_id).uniq).to eq([new_owner.tenant_id])
      expect(new_owner.items.map(&:owner_id).uniq).to eq([new_owner[:id]])
    end

    it "supports batching by an explicit cursor via HandlerApi#bulk_insert" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.composite_owners"
        self.primary_key = %i[tenant_id id]
        has_many :items,
          class_name: "Item",
          foreign_key: %i[tenant_id owner_id],
          primary_key: %i[tenant_id id]
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.composite_items"
        self.primary_key = %i[tenant_id id]
        belongs_to :owner,
          class_name: "Owner",
          foreign_key: %i[tenant_id owner_id],
          primary_key: %i[tenant_id id]
      end)

      original = Owner.create!(tenant_id: 1, name: "o")
      Item.create!(tenant_id: 1, owner_id: original[:id], label: "i1")
      Item.create!(tenant_id: 1, owner_id: original[:id], label: "i2")
      Item.create!(tenant_id: 1, owner_id: original[:id], label: "i3")

      duplicator = described_class.new
      duplicator.on(Item) do |api, klass, records|
        # batch_size + cursor exercises the in_batches(cursor:) path, which is
        # required for composite pk tables that lack a single monotonic column.
        api.bulk_insert(klass, records, batch_size: 2, cursor: %i[tenant_id id])
      end

      new_owner = duplicator.duplicate(original, associations: [:items])

      expect(new_owner.items.count).to eq(3)
      expect(new_owner.items.map(&:label)).to match_array(%w[i1 i2 i3])
    end
  end
end
