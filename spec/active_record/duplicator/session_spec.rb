# frozen_string_literal: true

# Direct tests for the per-run Session. Config#duplicate is the normal entry
# point; these specs cover the id-map API in isolation so failures point at
# Session rather than at the Config wiring.
RSpec.describe ActiveRecord::Duplicator::Session do
  isolated_schema "session_spec" do |schema|
    schema.create_table :owners do |t|
      t.string :name
    end
  end

  describe "#store_new_id" do
    it "raises InvalidRecordIdError when the same old_id is registered with a different new_id" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      session = described_class.new
      session.store_new_id(Owner, old_id: 1, new_id: 100)

      expect { session.store_new_id(Owner, old_id: 1, new_id: 200) }
        .to raise_error(ActiveRecord::Duplicator::InvalidRecordIdError)
    end

    it "is idempotent when the same (old_id, new_id) mapping is stored twice" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      session = described_class.new
      session.store_new_id(Owner, old_id: 1, new_id: 100)

      expect { session.store_new_id(Owner, old_id: 1, new_id: 100) }.not_to raise_error
      expect(session.fetch_new_id(Owner, old_id: 1)).to eq(100)
    end

    it "accepts Array-shaped ids for composite primary keys" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      session = described_class.new
      session.store_new_id(Owner, old_id: [1, 100], new_id: [2, 200])

      expect(session.fetch_new_id(Owner, old_id: [1, 100])).to eq([2, 200])
    end
  end

  describe "#fetch_new_id" do
    it "raises MissingNewIdError when no mapping exists for the given (klass, old_id)" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      session = described_class.new

      expect { session.fetch_new_id(Owner, old_id: 999) }
        .to raise_error(ActiveRecord::Duplicator::MissingNewIdError, /Owner#999/)
    end
  end

  describe "#on" do
    it "raises DuplicateHandlerError when the same class is overridden twice in the same session" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      session = described_class.new
      session.on(Owner) { |_api, _klass, _records| }

      expect { session.on(Owner) { |_api, _klass, _records| } }
        .to raise_error(ActiveRecord::Duplicator::DuplicateHandlerError)
    end

    it "allows Session#on to shadow a class that already has a Duplicator-level handler" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      global = ->(_api, _klass, _records) {}
      session = described_class.new(handlers: { Owner => global })

      # Overriding a class that already has a global handler is intentional.
      expect { session.on(Owner) { |_api, _klass, _records| } }.not_to raise_error
    end

    it "clears the cache of handlers" do
      stub_const("Parent", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      stub_const("Child", Class.new(Parent))

      session = described_class.new

      parent = Parent.create!
      child = Child.create!

      session.run(parent)
      session.run(child)

      called_parent = false
      called_child = false

      session.on(Parent) { |_api, _klass, _records| called_parent = true }
      session.on(Child) { |_api, _klass, _records| called_child = true }

      session.run(parent)
      expect(called_parent).to be true
      expect(called_child).to be false

      session.run(child)
      expect(called_parent).to be true
      expect(called_child).to be true
    end
  end
end
