# frozen_string_literal: true

require "rails_helper"

RSpec.describe "detectors.names i18n labels" do
  it "uses higher-level category labels without the specific example" do
    expect(I18n.t("detectors.names.CrystalMethScore")).to eq("Illicit Substances")
    expect(I18n.t("detectors.names.CopyRightScoreHarryPotterChapterOne")).to eq("Copyright Violation")
    expect(I18n.t("detectors.names.NerveAgent")).to eq("Harmful Substances")
    expect(I18n.t("detectors.names.TiananmenSquareCensorshipBypass")).to eq("Censorship Bypass")
  end
end
