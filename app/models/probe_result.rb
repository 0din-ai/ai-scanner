# frozen_string_literal: true

class ProbeResult < ApplicationRecord
  REPORT_PROBE_CARD_COLUMNS = %i[
    id
    report_id
    probe_id
    detector_id
    threat_variant_id
    passed
    total
    max_score
    input_tokens
    output_tokens
    any_detector_passed
  ].freeze

  belongs_to :report
  belongs_to :probe
  belongs_to :detector
  belongs_to :threat_variant, optional: true

  scope :for_report_probe_cards, -> { select(*REPORT_PROBE_CARD_COLUMNS).includes(:probe, :detector).readonly }

  validates :report_id, uniqueness: { scope: [ :probe_id, :threat_variant_id ] }

  before_validation :normalize_attempts

  def asr_percentage
    return 0 if total.nil? || total.zero?

    (passed.to_f / total * 100).round
  end

  # Counter cache callbacks - maintain cached stats on Probe model
  # Use after_*_commit for transaction safety (no updates for rolled-back transactions)
  after_create_commit :increment_probe_stats
  after_update_commit :adjust_probe_stats, if: :stats_changed?
  after_destroy_commit :decrement_probe_stats

  private

  def normalize_attempts
    self.attempts = [] if attempts.nil?
  end

  # Thread-safe atomic increment using SQL expressions
  def increment_probe_stats
    return if probe_id.blank?
    return if passed.to_i.zero? && total.to_i.zero?

    Probe.where(id: probe_id).update_all(
      sanitized_counter_update(passed.to_i, total.to_i)
    )
  end

  # Thread-safe atomic decrement using SQL expressions
  # GREATEST prevents negative values from edge cases
  def decrement_probe_stats
    return if probe_id.blank?
    return if passed.to_i.zero? && total.to_i.zero?

    Probe.where(id: probe_id).update_all(
      sanitized_counter_update(-passed.to_i, -total.to_i)
    )
  end

  # Handle updates: apply delta (new value - old value)
  def adjust_probe_stats
    return if probe_id.blank?

    delta_passed = passed.to_i - passed_before_last_save.to_i
    delta_total = total.to_i - total_before_last_save.to_i

    return if delta_passed.zero? && delta_total.zero?

    Probe.where(id: probe_id).update_all(
      sanitized_counter_update(delta_passed, delta_total)
    )
  end

  # Sanitize SQL for counter updates to avoid SQL injection warnings
  # Uses GREATEST to prevent negative values from edge cases
  def sanitized_counter_update(passed_delta, total_delta)
    ActiveRecord::Base.sanitize_sql_array([
      "cached_passed_count = GREATEST(0, cached_passed_count + ?), " \
      "cached_total_count = GREATEST(0, cached_total_count + ?)",
      passed_delta.to_i,
      total_delta.to_i
    ])
  end

  def stats_changed?
    saved_change_to_passed? || saved_change_to_total?
  end
end
