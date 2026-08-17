# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scans::ProjectedFigure do
  it "reports an amount when the figure was measured" do
    figure = described_class.new(amount: 82_765, basis: :measured, covered: 13, total: 13)

    expect(figure).to be_available
    expect(figure).to be_measured
    expect(figure.amount).to eq(82_765)
  end

  it "has no amount when nothing could be projected" do
    # The defect this type exists to prevent: an unprojectable scan rendered "~598"
    # as though it were a measurement.
    figure = described_class.new(amount: nil, basis: :unavailable, covered: 0, total: 13)

    expect(figure).not_to be_available
    expect(figure.amount).to be_nil
  end

  it "distinguishes an estimate from a measurement" do
    figure = described_class.new(amount: 2_990, basis: :estimated, covered: 4, total: 13)

    expect(figure).to be_available
    expect(figure).not_to be_measured
  end

  it "states its coverage so a surface can show the basis" do
    figure = described_class.new(amount: 100, basis: :measured, covered: 12, total: 13)

    expect(figure.coverage_sentence).to eq("12 of 13 probes covered")
  end

  it "treats a zero amount as a real figure, not as missing" do
    figure = described_class.new(amount: 0, basis: :measured, covered: 2, total: 2)

    expect(figure).to be_available
    expect(figure.amount).to eq(0)
  end

  it "refuses a basis it does not recognise" do
    # The three states are the whole point of this type; an unrecognised fourth would
    # silently render as though it were a measurement.
    expect {
      described_class.new(amount: 1, basis: :guessed, covered: 1, total: 1)
    }.to raise_error(ArgumentError, /guessed/)
  end
end
