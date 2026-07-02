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
    schema.create_table :sti_items do |t|
      t.string :type
      t.bigint :owner_id
      t.string :label
      t.timestamps
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
            owner_id: api.fetch_new_id(Owner, old_id: record.owner_id),
            label: "handled_#{record.label}",
          )
          api.store_new_id(klass, old_id: record.id, new_id: new_item.id)
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

    it "yields a fresh Session to the block so the caller can mark_skip parents" do
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
        session.mark_skip(tag)
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
        session.mark_skip(original)
      end

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
            owner_id: api.fetch_new_id(Owner, old_id: record.owner_id),
            label: "global_#{record.label}",
          )
          api.store_new_id(klass, old_id: record.id, new_id: new_item.id)
        end
      end

      overridden = duplicator.duplicate(original, associations: [:items]) do |session|
        session.on(Item) do |api, klass, records|
          records.each do |record|
            new_item = klass.create!(
              owner_id: api.fetch_new_id(Owner, old_id: record.owner_id),
              label: "session_#{record.label}",
            )
            api.store_new_id(klass, old_id: record.id, new_id: new_item.id)
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

  describe "with STI subclasses" do
    # Item hierarchy for these tests:
    #   Item
    #   ├── MusicItem
    #   │   └── GameItem
    #   └── PointItem
    def stub_sti_models
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
        has_many :items, class_name: "Item"
      end)
      stub_const("Item", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.sti_items"
        belongs_to :owner, class_name: "Owner"
      end)
      stub_const("MusicItem", Class.new(Item))
      stub_const("PointItem", Class.new(Item))
      stub_const("GameItem", Class.new(MusicItem))
    end

    it "on(base) fires for every subclass" do
      stub_sti_models

      original = Owner.create!(name: "o")
      MusicItem.create!(owner: original, label: "m")
      PointItem.create!(owner: original, label: "p")
      GameItem.create!(owner: original, label: "g")

      seen = []
      duplicator = described_class.new
      duplicator.on(Item) do |api, klass, records|
        seen << [klass, records.map(&:label)]
        api.bulk_insert(klass, records)
      end

      new_owner = duplicator.duplicate(original, associations: [:items])

      expect(seen.map(&:first)).to match_array([MusicItem, PointItem, GameItem])
      expect(new_owner.items.pluck(:type, :label))
        .to match_array([%w[MusicItem m], %w[PointItem p], %w[GameItem g]])
    end

    it "on(subclass) shadows on(base) for that subclass and its descendants" do
      stub_sti_models

      original = Owner.create!(name: "o")
      MusicItem.create!(owner: original, label: "m")
      PointItem.create!(owner: original, label: "p")
      GameItem.create!(owner: original, label: "g")

      music_calls = []
      item_calls = []
      duplicator = described_class.new
      duplicator.on(Item) do |api, klass, records|
        item_calls << [klass, records.map(&:label)]
        api.bulk_insert(klass, records)
      end
      duplicator.on(MusicItem) do |api, klass, records|
        music_calls << [klass, records.map(&:label)]
        api.bulk_insert(klass, records)
      end

      duplicator.duplicate(original, associations: [:items])

      # MusicItem handler catches MusicItem and GameItem (descendant of MusicItem);
      # Item handler catches only PointItem.
      expect(music_calls.map(&:first)).to match_array([MusicItem, GameItem])
      expect(item_calls.map(&:first)).to eq([PointItem])
    end

    it "on(deep subclass) only affects that exact subclass" do
      stub_sti_models

      original = Owner.create!(name: "o")
      MusicItem.create!(owner: original, label: "m")
      PointItem.create!(owner: original, label: "p")
      GameItem.create!(owner: original, label: "g")

      game_calls = []
      item_calls = []
      duplicator = described_class.new
      duplicator.on(Item) do |api, klass, records|
        item_calls << [klass, records.map(&:label)]
        api.bulk_insert(klass, records)
      end
      duplicator.on(GameItem) do |api, klass, records|
        game_calls << [klass, records.map(&:label)]
        api.bulk_insert(klass, records)
      end

      duplicator.duplicate(original, associations: [:items])

      # GameItem is a subclass of MusicItem, so on(MusicItem) is not involved
      # here; on(GameItem) only affects GameItem itself and Item handles the
      # rest (MusicItem, PointItem).
      expect(game_calls.map(&:first)).to eq([GameItem])
      expect(item_calls.map(&:first)).to match_array([MusicItem, PointItem])
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
        session.mark_skip(original)
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
      # in_batches(cursor:) was introduced in ActiveRecord 8.0; on 7.2 the
      # keyword is rejected. Skip cleanly so the same spec suite passes across
      # every supported Rails version.
      if Gem::Version.new(ActiveRecord::VERSION::STRING) < Gem::Version.new("8.0")
        skip "in_batches(cursor:) requires ActiveRecord >= 8.0"
      end

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
