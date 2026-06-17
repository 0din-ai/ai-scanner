# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminMenu do
  # Build with nil context: context-gated items (settings/integrations/companies)
  # compact out, leaving the always-present items including the core trio.
  let(:items) { described_class.build.items }

  def find_item(id)
    items.find { |i| i.id == id }
  end

  it "gives the core trio explanatory subtitles (V2 copy)" do
    expect(find_item("targets").subtitle).to eq("the AI models you test")
    expect(find_item("scans").subtitle).to eq("pick probes & attack a target")
    expect(find_item("reports").subtitle).to eq("findings from each scan")
  end

  it "leaves non-core items without a subtitle" do
    expect(find_item("dashboard").subtitle).to be_nil
    expect(find_item("probes").subtitle).to be_nil
  end

  it "orders the nav Targets -> Scans -> Reports" do
    ids = items.map(&:id)
    expect(ids.index("targets")).to be < ids.index("scans")
    expect(ids.index("scans")).to be < ids.index("reports")
  end
end
