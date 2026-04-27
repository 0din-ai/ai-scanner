require "rails_helper"

RSpec.describe GarakEvalRowValidator, type: :service do
  let(:valid_row) do
    {
      "entry_type" => "eval",
      "probe" => "0din.TestProbe",
      "detector" => "detector.test",
      "passed" => 2,
      "total_evaluated" => 5
    }
  end

  it "accepts structurally valid garak eval rows" do
    result = described_class.call(valid_row, require_probe_detector: true)

    expect(result).to be_valid
    expect(result.passed).to eq(2)
    expect(result.total_evaluated).to eq(5)
  end

  it "does not require probe and detector unless requested" do
    row = valid_row.except("probe", "detector")

    expect(described_class.call(row)).to be_valid
    expect(described_class.call(row, require_probe_detector: true)).not_to be_valid
  end

  it "rejects legacy eval rows that only contain total" do
    row = valid_row.except("total_evaluated").merge("total" => 5)

    expect(described_class.call(row)).not_to be_valid
  end

  it "rejects non-eval rows and non-object rows" do
    expect(described_class.call(valid_row.merge("entry_type" => "attempt"))).not_to be_valid
    expect(described_class.call([ valid_row ])).not_to be_valid
  end

  it "requires integer count fields" do
    invalid_values = [ nil, "2", 2.0, 2.5, Float::NAN, Float::INFINITY, -Float::INFINITY ]

    invalid_values.each do |value|
      expect(described_class.call(valid_row.merge("passed" => value))).not_to be_valid
      expect(described_class.call(valid_row.merge("total_evaluated" => value))).not_to be_valid
    end
  end

  it "rejects negative counts" do
    expect(described_class.call(valid_row.merge("passed" => -1))).not_to be_valid
    expect(described_class.call(valid_row.merge("total_evaluated" => -1))).not_to be_valid
  end

  it "rejects zero totals and passed counts greater than total_evaluated" do
    expect(described_class.call(valid_row.merge("total_evaluated" => 0))).not_to be_valid
    expect(described_class.call(valid_row.merge("passed" => 6, "total_evaluated" => 5))).not_to be_valid
  end

  it "requires present probe and detector strings when requested" do
    expect(described_class.call(valid_row.merge("probe" => ""), require_probe_detector: true)).not_to be_valid
    expect(described_class.call(valid_row.merge("detector" => nil), require_probe_detector: true)).not_to be_valid
  end
end
