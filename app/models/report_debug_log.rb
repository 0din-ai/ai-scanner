# frozen_string_literal: true

class ReportDebugLog < ApplicationRecord
  TAIL_RESET_ATTRIBUTES = {
    tail: nil,
    tail_offset: 0,
    tail_digest: nil,
    tail_synced_at: nil,
    tail_truncated: false
  }.freeze

  belongs_to :report

  validates :report_id, uniqueness: true

  def self.clear_tail_for_report(report_id)
    where(report_id: report_id).update_all(TAIL_RESET_ATTRIBUTES.merge(updated_at: Time.current))
  end
end
