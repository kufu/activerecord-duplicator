# frozen_string_literal: true

# HandlerApi is a facade over Session that only exposes the subset a handler
# should call. Verifying the forwarding shape with instance_double keeps the
# public surface in sync with Session's method signatures.
RSpec.describe ActiveRecord::Duplicator::HandlerApi do
  it "forwards mark_skip to the wrapped Session including splat args" do
    session = instance_double(ActiveRecord::Duplicator::Session)
    record_a = double("record_a")
    record_b = double("record_b")
    expect(session).to receive(:mark_skip).with(record_a, record_b)

    described_class.new(session).mark_skip(record_a, record_b)
  end

  it "forwards store_new_id to the wrapped Session including keyword args" do
    session = instance_double(ActiveRecord::Duplicator::Session)
    klass = Class.new
    expect(session).to receive(:store_new_id).with(klass, old_id: 1, new_id: 2)

    described_class.new(session).store_new_id(klass, old_id: 1, new_id: 2)
  end

  it "forwards fetch_new_id to the wrapped Session and returns its value" do
    session = instance_double(ActiveRecord::Duplicator::Session)
    klass = Class.new
    expect(session).to receive(:fetch_new_id).with(klass, old_id: 1).and_return(42)

    expect(described_class.new(session).fetch_new_id(klass, old_id: 1)).to eq(42)
  end

  it "forwards bulk_insert to the wrapped Session including keyword args" do
    session = instance_double(ActiveRecord::Duplicator::Session)
    klass = Class.new
    records = double("records")
    expect(session).to receive(:bulk_insert).with(klass, records, batch_size: 5, cursor: %i[a b])

    described_class.new(session).bulk_insert(klass, records, batch_size: 5, cursor: %i[a b])
  end

  it "forwards attributes_for to the wrapped Session and returns its value" do
    session = instance_double(ActiveRecord::Duplicator::Session)
    klass = Class.new
    record = double("record")
    expect(session).to receive(:attributes_for).with(klass, record).and_return({ "a" => 1 })

    expect(described_class.new(session).attributes_for(klass, record)).to eq({ "a" => 1 })
  end
end
