# frozen_string_literal: true

module Reports
  # One attack-success-rate reading, and the only thing a surface may render.
  #
  # It exists to keep two facts apart that the previous Float could not:
  #
  #   0.0  -- attacks were evaluated and none succeeded (a real, good result)
  #   nil  -- nothing was measurable, so no rate can be stated
  #
  # Report#attack_success_rate collapsed both to 0, and #formatted_asr then rendered
  # every zero as "N/A". A completed scan that blocked all three attacks reported
  # "unavailable" next to its own 0/3 counts, while the overview said 0.0% for the same
  # data. Callers now ask #calculable? instead of comparing against zero.
  #
  # Rounding is deliberately NOT done here: this is the value, and how many decimals a
  # given surface shows is a display decision (see ReportsHelper#asr_display).
  class AsrFigure
    attr_reader :numerator, :denominator

    def initialize(numerator:, denominator:, partial: false)
      @numerator = numerator.to_i
      @denominator = denominator.to_i
      @partial = partial
    end

    # A rate can only be stated over something. A zero or negative denominator means the
    # run recorded nothing to divide by, not that the rate happens to be zero.
    def calculable?
      denominator.positive?
    end

    # The rate, or nil when there is nothing to compute it over. Never 0.0 as a stand-in
    # for "unknown" -- that conflation is the whole reason this type exists.
    def percent
      return nil unless calculable?

      numerator.to_f / denominator * 100
    end

    # Whether the run behind this figure holds only part of its planned work, so a
    # surface can say the rate covers recorded work alone.
    def partial?
      @partial
    end
  end
end
