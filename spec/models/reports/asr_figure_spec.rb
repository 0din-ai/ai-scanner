# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reports::AsrFigure do
  # The defect this type exists to remove: Report#attack_success_rate returned 0 both
  # when nothing succeeded and when nothing could be measured, and #formatted_asr then
  # rendered every zero as "N/A". A completed scan that blocked all three attacks -- the
  # best possible outcome -- read as "unavailable" beside its own 0/3 counts.
  describe "the zero it can calculate" do
    subject(:figure) { described_class.new(numerator: 0, denominator: 3) }

    it "is calculable" do
      expect(figure).to be_calculable
    end

    it "has a percentage of zero rather than nothing" do
      expect(figure.percent).to eq(0.0)
    end
  end

  describe "the zero it cannot calculate" do
    subject(:figure) { described_class.new(numerator: 0, denominator: 0) }

    it "is not calculable" do
      expect(figure).not_to be_calculable
    end

    it "has no percentage at all, so no caller can mistake it for zero" do
      expect(figure.percent).to be_nil
    end
  end

  describe "#percent" do
    it "is the unrounded ratio; rounding belongs to display" do
      figure = described_class.new(numerator: 5959, denominator: 7866)

      expect(figure.percent).to be_within(0.0001).of(75.7564199)
    end

    it "is 100 when every attack succeeded" do
      expect(described_class.new(numerator: 4, denominator: 4).percent).to eq(100.0)
    end
  end

  describe "#partial?" do
    it "carries the completeness of the run it came from" do
      expect(described_class.new(numerator: 1, denominator: 2, partial: true)).to be_partial
      expect(described_class.new(numerator: 1, denominator: 2)).not_to be_partial
    end
  end

  describe "a negative or nonsense denominator" do
    it "is not calculable rather than raising or inverting" do
      figure = described_class.new(numerator: 1, denominator: -3)

      expect(figure).not_to be_calculable
      expect(figure.percent).to be_nil
    end

    it "treats a nil denominator as unmeasured" do
      figure = described_class.new(numerator: nil, denominator: nil)

      expect(figure).not_to be_calculable
      expect(figure.percent).to be_nil
    end
  end
end
