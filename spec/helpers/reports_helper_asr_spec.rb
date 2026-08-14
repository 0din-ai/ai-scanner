# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReportsHelper, type: :helper do
  # Every surface renders ASR through this one helper. The four cases below are the
  # semantics the ticket pins: N/A only when nothing is measurable, 0.0% for a real
  # zero, one precision everywhere, and partial evidence said so.
  describe "#asr_display" do
    def figure(numerator, denominator, partial: false)
      Reports::AsrFigure.new(numerator: numerator, denominator: denominator, partial: partial)
    end

    it "renders a real zero as a percentage, not as unavailable" do
      expect(helper.asr_display(figure(0, 3))).to eq("0.0%")
    end

    it "renders N/A only when there is nothing to divide by" do
      expect(helper.asr_display(figure(0, 0))).to eq("N/A")
    end

    it "uses one decimal place by default" do
      expect(helper.asr_display(figure(5959, 7866))).to eq("75.8%")
      expect(helper.asr_display(figure(8888, 10678))).to eq("83.2%")
    end

    it "accepts a coarser precision for the customer headline, the one documented exception" do
      expect(helper.asr_display(figure(8888, 10678), precision: 0)).to eq("83%")
    end

    it "does not round a real zero away into N/A at any precision" do
      expect(helper.asr_display(figure(0, 3), precision: 0)).to eq("0%")
    end
  end
end
