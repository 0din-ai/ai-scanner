# frozen_string_literal: true

require "rails_helper"

RSpec.describe Detector, "display naming" do
  # Detector labels were built inline in four places as
  # I18n.t("detectors.names.#{name.split('.').last}"), keying on the last segment alone.
  # Two detectors from different namespaces therefore rendered the same friendly name with
  # different numbers beside them, which is what made a report's rows look contradictory.
  describe ".display_label" do
    it "uses the friendly name for a known detector" do
      expect(described_class.display_label("0din.MitigationBypass")).to eq("Generic Mitigation Bypass Checks")
    end

    it "falls back to the bare class name when there is no friendly name" do
      expect(described_class.display_label("divergence.Repeat")).to eq("Repeat")
    end

    it "handles an unqualified name" do
      expect(described_class.display_label("MitigationBypass")).to eq("Generic Mitigation Bypass Checks")
    end

    it "tolerates a missing name" do
      expect(described_class.display_label(nil)).to eq("Unknown")
    end
  end

  describe ".qualifier_for" do
    # The qualifier is what tells two identically-labelled rows apart.
    it "is the full identifier when the friendly name hides it" do
      expect(described_class.qualifier_for("0din.MitigationBypass")).to eq("0din.MitigationBypass")
      expect(described_class.qualifier_for("mitigation.MitigationBypass")).to eq("mitigation.MitigationBypass")
    end

    it "distinguishes two detectors that share a friendly name" do
      a = "0din.MitigationBypass"
      b = "mitigation.MitigationBypass"

      expect(described_class.display_label(a)).to eq(described_class.display_label(b))
      expect(described_class.qualifier_for(a)).not_to eq(described_class.qualifier_for(b))
    end

    it "is nil when the label already says everything the identifier does" do
      # No friendly mapping and no namespace: the label IS the identifier, so repeating it
      # underneath would be noise.
      expect(described_class.qualifier_for("Repeat")).to be_nil
    end

    it "tolerates a missing name" do
      expect(described_class.qualifier_for(nil)).to be_nil
    end
  end

  describe "#display_label" do
    it "reads from the record's own name" do
      detector = build(:detector, name: "0din.MitigationBypass")

      expect(detector.display_label).to eq("Generic Mitigation Bypass Checks")
      expect(detector.qualifier).to eq("0din.MitigationBypass")
    end
  end
end
