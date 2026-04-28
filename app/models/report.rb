class Report < ApplicationRecord
  include VariantDefaults

  acts_as_tenant :company
  belongs_to :target
  belongs_to :scan, counter_cache: true
  has_many :probe_results, dependent: :destroy
  has_many :detector_results, dependent: :destroy
  has_many :detectors, through: :detector_results
  belongs_to :parent_report, class_name: "Report", optional: true
  has_one :child_report, class_name: "Report", foreign_key: "parent_report_id", dependent: :destroy
  has_one :raw_report_data, dependent: :destroy
  has_one :report_debug_log, dependent: :destroy, autosave: true
  has_one :report_pdf, dependent: :destroy

  validates :uuid, presence: true, uniqueness: true
  validates :target, presence: true
  validates :scan, presence: true

  before_validation :generate_uuid, if: :new_record?
  before_validation :generate_name, if: :new_record?

  scope :running, -> { where(status: :running) }
  scope :active, -> { where(status: [ :running, :starting ]) }
  scope :sorted, -> { order(:created_at) }
  scope :parent_reports, -> { where(parent_report_id: nil) }
  scope :child_reports_only, -> { where.not(parent_report_id: nil) }

  # Pre-calculate detector stats to avoid N+1 queries on index pages
  # Adds virtual attributes: cached_passed, cached_total
  scope :with_detector_stats, -> {
    left_joins(:detector_results)
      .group("reports.id")
      .select(
        "reports.*",
        "COALESCE(SUM(detector_results.passed), 0) as cached_passed",
        "COALESCE(SUM(detector_results.total), 0) as cached_total"
      )
  }

  after_update do
    if saved_change_to_status?
      notify_status_change
      update_scan_cache
      collect_metrics
      refund_scan_quota
    end
  end

  # Trigger widget broadcast when status affects running count (multi-pod safe)
  after_commit :broadcast_running_stats_if_needed, if: :saved_change_to_status?
  after_commit :broadcast_debug_stream_if_watched, if: :saved_change_to_status?

  enum :status, {
    pending: 0,
    starting: 6,
    running: 1,
    processing: 2,
    completed: 3,
    failed: 4,
    stopped: 5,
    interrupted: 7
  }

  # Status constants
  # - processing/starting are internal transition states, not shown to users
  # - interrupted is visible so users can monitor auto-retry behavior
  ACTIONABLE_STATUSES = (statuses.keys - %w[processing starting]).freeze
  BROADCAST_ACTIVE_STATUSES = %w[running starting].freeze
  DEBUG_BROADCAST_ACTIVE_STATUSES = (BROADCAST_ACTIVE_STATUSES + %w[processing]).freeze
  DEBUG_STREAM_LIVE_TAIL_STATUSES = %w[running processing].freeze
  DEBUG_STREAM_POLLING_STATUSES = (DEBUG_BROADCAST_ACTIVE_STATUSES + %w[pending]).freeze

  def self.ransackable_attributes(auth_object = nil)
    [ "company_id", "name", "created_at", "id", "status", "target_id", "updated_at", "uuid", "asr" ]
  end

  def self.ransackable_associations(auth_object = nil)
    [ "company", "target", "scan" ]
  end

  def logs
    debug_logs = report_debug_log&.logs if report_debug_logs_table_available?
    return debug_logs unless debug_logs.nil?

    legacy_logs_value
  end

  def logs=(value)
    if report_debug_logs_table_available?
      debug_log = report_debug_log || find_or_build_report_debug_log
      debug_log.logs = value
    end

    self[:logs] = value if has_attribute?(:logs)
    value
  end

  def detector_results_as_hash
    result = {}
    detector_results.includes(:detector).each do |detector_result|
      detector_name = detector_result.detector&.name || "Unknown"
      result[detector_name] = {
        "passed" => detector_result.passed,
        "total" => detector_result.total,
        "max_score" => detector_result.max_score
      }
    end
    result
  end

  # Cached accessor for passed count - uses preloaded value if available, otherwise queries
  def cached_passed
    return read_attribute(:cached_passed).to_i if has_attribute?(:cached_passed)
    detector_results.sum(:passed)
  end

  # Cached accessor for total count - uses preloaded value if available, otherwise queries
  def cached_total
    return read_attribute(:cached_total).to_i if has_attribute?(:cached_total)
    detector_results.sum(:total)
  end

  def attack_success_rate
    total = cached_total
    passed = cached_passed
    return 0 if total == 0
    (passed.to_f / total * 100).round(2)
  end

  def formatted_asr
    asr = attack_success_rate
    asr == 0 ? "N/A" : "#{asr}%"
  end

  def total_successful_attacks
    cached_passed
  end

  def total_attacks
    cached_total
  end

  def security_vulnerabilities_count
    # Count detector results where there were failures (passed < total)
    detector_results.where("passed < total").count
  end

  # Compute total input tokens from all probe results
  # Memoized since token counts don't change once report is completed
  def input_tokens
    @input_tokens ||= probe_results.sum(:input_tokens)
  end

  # Compute total output tokens from all probe results
  # Memoized since token counts don't change once report is completed
  def output_tokens
    @output_tokens ||= probe_results.sum(:output_tokens)
  end

  def total_tokens
    input_tokens + output_tokens
  end

  private

  def find_or_build_report_debug_log
    if persisted?
      ReportDebugLog.find_or_initialize_by(report_id: id).tap do |record|
        self.report_debug_log = record
      end
    else
      build_report_debug_log
    end
  end

  def legacy_logs_value
    self[:logs] if has_attribute?(:logs)
  end

  def report_debug_logs_table_available?
    self.class.connection.data_source_exists?("report_debug_logs")
  end

  # Failed/stopped scans should not count against the company's weekly quota.
  # Decrements the scan count so the user can retry without being penalized.
  def refund_scan_quota
    return unless failed? || stopped?
    company&.decrement_scan_count!
  end

  def generate_uuid
    self.uuid = SecureRandom.uuid
  end

  def generate_name
    self.name = "#{target.name} - #{scan.name} - #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}" unless self.name
  end

  def update_scan_cache
    if completed? || failed?
      scan.with_lock do
        scan.update_avg_successful_attacks!
      end
    end
  end

  # Broadcasts widget update when transitioning to/from active states.
  # Uses after_commit to ensure transaction is complete before job runs.
  # Only broadcasts when the change affects the running count.
  def broadcast_running_stats_if_needed
    old_status, new_status = saved_change_to_status
    return unless old_status && new_status

    # Only broadcast when transitioning to/from an active state
    affects_count = BROADCAST_ACTIVE_STATUSES.include?(old_status.to_s) ||
                    BROADCAST_ACTIVE_STATUSES.include?(new_status.to_s)

    # Pass company_id for company-scoped broadcast
    BroadcastRunningStatsJob.perform_later(company_id) if affects_count
  end

  def broadcast_debug_stream_if_watched
    return unless Reports::DebugWatcher.watching?(id)

    _old_status, new_status = saved_change_to_status
    BroadcastReportDebugJob.enqueue_status_change(id, new_status)
  end

  def collect_metrics
    Rails.logger.info("[Monitoring] collect_metrics called for report #{uuid}, status: #{status}, monitoring active: #{MonitoringService.active?}, saved_change: #{saved_change_to_status?}")

    return unless MonitoringService.active?
    return unless saved_change_to_status?

    if MonitoringService.current_trace_id
      Rails.logger.info("[Monitoring] Collecting metrics for report #{uuid} (status: #{status}, trace_id: #{MonitoringService.current_trace_id})")
      collect_metrics_in_transaction
    else
      Rails.logger.info("[Monitoring] Creating transaction for metrics collection - report #{uuid} (status: #{status})")
      MonitoringService.transaction("report_metrics", "custom") do
        collect_metrics_in_transaction
      end
    end

    Rails.logger.info("[Monitoring] Metrics collected successfully for report #{uuid}")
  end

  def collect_metrics_in_transaction
    case status.to_sym
    when :starting
      Rails.logger.info("Recording queue wait metric for report #{uuid}")
      record_queue_wait_metric
    when :completed, :failed, :stopped, :interrupted
      Rails.logger.info("Recording scan completion metrics for report #{uuid} (status: #{status})")
      record_all_completion_metrics
    else
      Rails.logger.debug("Skipping metrics for report #{uuid} status: #{status}")
    end
  end

  def record_queue_wait_metric
    wait_time = (updated_at - created_at).to_i

    Rails.logger.info("[Monitoring Metrics] Recording queue_wait_seconds = #{wait_time} for report #{uuid}")

    labels = build_base_metric_labels.merge(
      queue_wait_seconds: wait_time
    )

    MonitoringService.set_labels(labels)

    Rails.logger.info("[Monitoring Metrics] Labels set: queue_wait_seconds=#{wait_time}")
  end

  def record_all_completion_metrics
    return unless created_at

    duration = (updated_at - created_at).to_i
    status_value = completed? ? 1 : 0

    labels = build_base_metric_labels.merge(
      scan_status: status.to_s,
      scan_success: status_value,
      scan_duration_seconds: duration,
      is_variant: is_variant_report?
    )

    if completed?
      labels.merge!(
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: input_tokens + output_tokens
      )

      if scan.projected_input_tokens > 0
        deviation = ((input_tokens - scan.projected_input_tokens).to_f / scan.projected_input_tokens * 100).round(2)
        labels[:token_deviation_percent] = deviation
        labels[:projected_input_tokens] = scan.projected_input_tokens
      end
    end

    MonitoringService.set_labels(labels)
  end

  # These allow filtering and grouping in monitoring dashboards
  # Returns a hash instead of setting labels directly for batch optimization
  def build_base_metric_labels
    {
      target_name: target.name,
      target_model: target.model,
      scan_name: scan.name,
      scan_id: scan.id,
      report_uuid: uuid,
      trace_id: monitoring_trace_id
    }
  end

  def monitoring_trace_id
    return "none" unless MonitoringService.active?
    @monitoring_trace_id ||= MonitoringService.current_trace_id || "none"
  end
end
