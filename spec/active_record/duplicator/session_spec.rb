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

  describe "#run" do
    it "invokes root_record.transaction with no options when transaction_options is not given" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)
      original = Owner.create!(name: "o")

      # Default is `transaction_options: {}` → plain `transaction do ... end`
      # with no keyword args. The previous requires_new: true / joinable: false
      # defaults were removed so the caller controls isolation entirely.
      expect(original).to receive(:transaction).with(no_args).and_call_original

      described_class.new.run(original)
    end

    it "forwards transaction_options verbatim to root_record.transaction" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)
      original = Owner.create!(name: "o")

      expect(original)
        .to receive(:transaction)
        .with(requires_new: true, joinable: false)
        .and_call_original

      described_class.new.run(original, transaction_options: { requires_new: true, joinable: false })
    end
  end

  describe "#mark_skip_class" do
    it "makes fetch_new_id return the queried old_id without consulting the id map" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      session = described_class.new
      session.mark_skip_class(Owner)

      # No store_new_id was ever called for Owner — the map is empty. Without
      # mark_skip_class this would raise MissingNewIdError; with it the class
      # short-circuits and the old_id echoes back unchanged.
      expect(session.fetch_new_id(Owner, old_id: 42)).to eq(42)
      expect(session.fetch_new_id(Owner, old_id: [1, 2])).to eq([1, 2])
    end

    it "accepts multiple classes at once" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)
      stub_const("Other", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      session = described_class.new
      session.mark_skip_class(Owner, Other)

      expect(session.fetch_new_id(Owner, old_id: 1)).to eq(1)
      expect(session.fetch_new_id(Other, old_id: 2)).to eq(2)
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

    it "applies to subsequent runs even after a prior handler-less run" do
      stub_const("Owner", Class.new(ActiveRecord::Base) do
        self.table_name = "session_spec.owners"
      end)

      session = described_class.new
      original = Owner.create!(name: "o")

      session.run(original)

      called = false
      session.on(Owner) { |_api, _klass, _records| called = true }

      session.run(original)
      expect(called).to be true
    end
  end
end
