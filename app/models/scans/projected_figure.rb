# frozen_string_literal: true

module Scans
  # One projected quantity — input tokens, output tokens, or runtime seconds — together
  # with how it was arrived at.
  #
  # It exists to keep three states apart that a plain Integer could not:
  #
  #   measured     -- derived from what these probes actually cost before
  #   estimated    -- derived from static prompt text, because they have never run
  #   unavailable  -- neither basis exists; no number can honestly be shown
  #
  # The previous projection collapsed all three into one Integer, so a scan whose probes
  # generate their prompts at runtime -- and therefore store no prompt text at all --
  # projected 598 tokens against an actual 84,756. Surfaces now ask #available? rather
  # than treating a small number as a measurement.
  class ProjectedFigure
    BASES = %i[measured estimated unavailable].freeze

    attr_reader :amount, :basis, :covered, :total

    def initialize(amount:, basis:, covered: 0, total: 0)
      raise ArgumentError, "unknown basis #{basis.inspect}" unless BASES.include?(basis)

      @amount = amount
      @basis = basis
      @covered = covered.to_i
      @total = total.to_i
    end

    # Zero is a real projection (an empty scan costs nothing). Absence is nil.
    def available?
      !amount.nil?
    end

    def measured?
      basis == :measured
    end

    def coverage_sentence
      "#{covered} of #{total} probes covered"
    end
  end
end
