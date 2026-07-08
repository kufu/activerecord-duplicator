# frozen_string_literal: true

RSpec.describe ActiveRecord::Duplicator::AssociationTraversal do
  isolated_schema "traversal_spec" do |schema|
    schema.create_table :owners do |t|
      t.string :name
    end
    schema.create_table :items do |t|
      t.bigint :owner_id
      t.string :label
    end
    schema.create_table :profiles do |t|
      t.bigint :owner_id
      t.string :bio
    end
    schema.create_table :tags do |t|
      t.string :name
    end
    schema.create_table :item_taggings do |t|
      t.bigint :item_id
      t.bigint :tag_id
    end
  end

  it "yields nothing when associations is an empty array" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
    end)

    owner = Owner.create!(name: "o")

    result = described_class.new(owner, []).to_a

    expect(result).to eq([])
  end

  it "yields a single Relation when traversing one has_many association" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
      has_many :items, class_name: "Item"
    end)
    stub_const("Item", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_items"
      belongs_to :owner, class_name: "Owner"
    end)

    owner = Owner.create!(name: "o")
    owner.items.create!(label: "i1")
    owner.items.create!(label: "i2")

    result = described_class.new(owner, [:items]).to_a

    expect(result.size).to eq(1)
    expect(result[0]).to be_a(ActiveRecord::Relation)
    expect(result[0]).to match_array(owner.items)
  end

  it "yields a single Relation when traversing one has_one association" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
      has_one :profile, class_name: "Profile"
    end)
    stub_const("Profile", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_profiles"
      belongs_to :owner, class_name: "Owner"
    end)

    owner = Owner.create!(name: "o")
    profile = Profile.create!(owner:, bio: "hi")

    result = described_class.new(owner, [:profile]).to_a

    expect(result.size).to eq(1)
    expect(result[0]).to be_a(ActiveRecord::Relation)
    expect(result[0].to_a).to eq([profile])
  end

  it "yields the parent Relation when traversing a belongs_to association" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
      has_many :items, class_name: "Item"
    end)
    stub_const("Item", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_items"
      belongs_to :owner, class_name: "Owner"
    end)

    owner = Owner.create!(name: "o")
    item = owner.items.create!(label: "i")

    result = described_class.new(item, [:owner]).to_a

    expect(result.size).to eq(1)
    expect(result[0]).to be_a(ActiveRecord::Relation)
    expect(result[0].to_a).to eq([owner])
  end

  it "resolves has_many :through by walking the intermediate reflection first" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
      has_many :items, class_name: "Item"
      has_many :item_taggings, through: :items, class_name: "ItemTagging"
    end)
    stub_const("Item", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_items"
      belongs_to :owner, class_name: "Owner"
      has_many :item_taggings, class_name: "ItemTagging"
    end)
    stub_const("Tag", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_tags"
    end)
    stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_item_taggings"
      belongs_to :item, class_name: "Item"
      belongs_to :tag, class_name: "Tag"
    end)

    owner = Owner.create!(name: "o")
    item = owner.items.create!(label: "i")
    ItemTagging.create!(item:, tag: Tag.create!(name: "t"))

    result = described_class.new(owner, [:item_taggings]).to_a

    expect(result.size).to eq(1)
    expect(result[0]).to be_a(ActiveRecord::Relation)
    expect(result[0].to_a).to match_array(owner.item_taggings)
  end

  it "yields nested associations breadth-first when given a Hash" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
      has_many :items, class_name: "Item"
    end)
    stub_const("Item", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_items"
      belongs_to :owner, class_name: "Owner"
      has_many :item_taggings, class_name: "ItemTagging"
    end)
    stub_const("Tag", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_tags"
    end)
    stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_item_taggings"
      belongs_to :item, class_name: "Item"
      belongs_to :tag, class_name: "Tag"
    end)

    owner = Owner.create!(name: "o")
    item = owner.items.create!(label: "i")
    tagging = ItemTagging.create!(item:, tag: Tag.create!(name: "t"))

    result = described_class.new(owner, [items: :item_taggings]).to_a

    expect(result.size).to eq(2)
    expect(result[0]).to be_a(ActiveRecord::Relation)
    expect(result[0].to_a).to eq([item])
    expect(result[1]).to be_a(ActiveRecord::Relation)
    expect(result[1].to_a).to eq([tagging])
  end

  it "still yields an empty Relation for descendant associations when the intermediate is empty" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
      has_many :items, class_name: "Item"
    end)
    stub_const("Item", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_items"
      belongs_to :owner, class_name: "Owner"
      has_many :item_taggings, class_name: "ItemTagging"
    end)
    stub_const("Tag", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_tags"
    end)
    stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_item_taggings"
      belongs_to :item, class_name: "Item"
      belongs_to :tag, class_name: "Tag"
    end)

    owner = Owner.create!(name: "o")

    result = described_class.new(owner, [items: :item_taggings]).to_a

    expect(result.size).to eq(2)
    expect(result[0]).to be_a(ActiveRecord::Relation)
    expect(result[0]).to be_empty
    expect(result[1]).to be_a(ActiveRecord::Relation)
    expect(result[1]).to be_empty
  end

  it "supports Enumerable methods such as reverse_each" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
      has_many :items, class_name: "Item"
    end)
    stub_const("Item", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_items"
      belongs_to :owner, class_name: "Owner"
      has_many :item_taggings, class_name: "ItemTagging"
    end)
    stub_const("Tag", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_tags"
    end)
    stub_const("ItemTagging", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_item_taggings"
      belongs_to :item, class_name: "Item"
      belongs_to :tag, class_name: "Tag"
    end)

    owner = Owner.create!(name: "o")
    item = owner.items.create!(label: "i")
    tagging = ItemTagging.create!(item:, tag: Tag.create!(name: "t"))

    result = described_class.new(owner, [items: :item_taggings]).reverse_each.to_a

    expect(result.size).to eq(2)
    expect(result[0].to_a).to eq([tagging])
    expect(result[1].to_a).to eq([item])
  end

  it "returns self when called with a block so Enumerable methods can chain" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
    end)

    owner = Owner.create!(name: "o")
    traversal = described_class.new(owner, [])

    expect(traversal.each { |_relation| }).to be(traversal)
  end

  it "returns an Enumerator when called without a block" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
    end)

    owner = Owner.create!(name: "o")
    traversal = described_class.new(owner, [])

    expect(traversal.each).to be_a(Enumerator)
  end

  it "raises ArgumentError when the association name does not exist" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
    end)

    owner = Owner.create!(name: "o")

    expect { described_class.new(owner, [:nonexistent]).to_a }
      .to raise_error(ArgumentError, /no association/)
  end

  it "raises ArgumentError for association specifications that are not Symbol/String/Hash" do
    stub_const("Owner", Class.new(ActiveRecord::Base) do
      self.table_name = "traversal_spec_owners"
    end)

    owner = Owner.create!(name: "o")

    expect { described_class.new(owner, [12_345]).to_a }
      .to raise_error(ArgumentError, /is not a valid association form/)
  end
end
