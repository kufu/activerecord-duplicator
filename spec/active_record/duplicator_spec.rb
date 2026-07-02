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
  end

  describe "VERSION" do
    it "is a non-nil string" do
      expect(ActiveRecord::Duplicator::VERSION).to be_a(String)
    end
  end

  describe ".new" do
    it "returns a Session instance" do
      duplicator = described_class.new
      expect(duplicator).to be_a(ActiveRecord::Duplicator::Session)
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
      expect(new_owner.items.map(&:label)).to match_array(["i1", "i2"])
      expect(new_owner.items.map(&:owner_id).uniq).to eq([new_owner.id])
    end

    it "duplicates nested associations via Hash syntax and keeps skipped records intact" do
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
      ItemTagging.create!(item: item, tag: tag)

      duplicator = described_class.new
      duplicator.mark_skip(tag)
      new_owner = duplicator.duplicate(original, associations: [items: :item_taggings])

      expect(new_owner.items.count).to eq(1)
      new_item = new_owner.items.first
      expect(new_item.label).to eq("i")
      expect(new_item.item_taggings.count).to eq(1)
      # Tag was skipped, so the tagging still references the original tag id
      expect(new_item.item_taggings.first.tag_id).to eq(tag.id)
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

  describe "#mark_skip" do
    it "prevents the given record from being duplicated by returning its original id" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      original = Owner.create!(name: "o")

      duplicator = described_class.new
      duplicator.mark_skip(original)
      result = duplicator.duplicate(original)

      expect(result.id).to eq(original.id)
    end
  end

  describe "#store_new_id" do
    it "raises InvalidRecordIdError when the same old_id is registered with a different new_id" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      duplicator = described_class.new
      duplicator.store_new_id(Owner, old_id: 1, new_id: 100)

      expect { duplicator.store_new_id(Owner, old_id: 1, new_id: 200) }
        .to raise_error(ActiveRecord::Duplicator::InvalidRecordIdError)
    end

    it "is idempotent when the same (old_id, new_id) mapping is stored twice" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      duplicator = described_class.new
      duplicator.store_new_id(Owner, old_id: 1, new_id: 100)

      expect { duplicator.store_new_id(Owner, old_id: 1, new_id: 100) }.not_to raise_error
      expect(duplicator.fetch_new_id(Owner, old_id: 1)).to eq(100)
    end
  end

  describe "#fetch_new_id" do
    it "raises MissingNewIdError when no mapping exists for the given (klass, old_id)" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "duplicator_spec.owners"
      end)

      duplicator = described_class.new

      expect { duplicator.fetch_new_id(Owner, old_id: 999) }
        .to raise_error(ActiveRecord::Duplicator::MissingNewIdError, /Owner#999/)
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
      expect(new_owner.items.map(&:label)).to match_array(["i1", "i2"])
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
end
