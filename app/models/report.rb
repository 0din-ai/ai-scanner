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


  # Pre-calculate result stats to avoid N+1 queries on index pages.
  # Adds virtual attributes: cached_passed, cached_total.
  #
  # Summed over probe_results, one row per attack: see #cached_total.
  scope :with_result_stats, -> {
    left_joins(:probe_results)
      .group("reports.id")
      .select(
        "reports.*",
        "COALESCE(SUM(probe_results.passed), 0) as cached_passed",
        "COALESCE(SUM(probe_results.total), 0) as cached_total"
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

  # Result completeness is independent of the execution lifecycle above. A scan can
  # fail or be stopped and still leave usable partial evidence; presenting that the
  # same way as a finished scan is what this separation exists to prevent.
  #
  # Prefixed so the predicates read as completeness rather than status
  # (`complete_results?`, not `complete?`).
  enum :result_completeness, {
    complete: "complete",
    partial: "partial",
    none: "none"
  }, suffix: :results

  # The stored value is authoritative, but it is not always present: a report can reach
  # a terminal state without passing through Reports::Process (an unsafe target, a
  # launch failure, a stop, the stale reaper), and during a rolling deploy an
  # old-version worker finishes in-flight reports without writing the column. Reading
  # those as "not partial" would silently present partial evidence as final, so the
  # predicates fall back to deriving it. Same rule as the backfill, one definition.
  def result_completeness
    super.presence || derived_result_completeness
  end

  def complete_results?
    result_completeness == "complete"
  end

  def partial_results?
    result_completeness == "partial"
  end

  def none_results?
    result_completeness == "none"
  end

  # Status constants
  # - processing/starting are internal transition states, not shown to users
  # - interrupted is visible so users can monitor auto-retry behavior
  ACTIONABLE_STATUSES = (statuses.keys - %w[processing starting]).freeze
  BROADCAST_ACTIVE_STATUSES = %w[running starting].freeze
  DEBUG_BROADCAST_ACTIVE_STATUSES = (BROADCAST_ACTIVE_STATUSES + %w[processing]).freeze
  DEBUG_STREAM_LIVE_TAIL_STATUSES = %w[running processing].freeze
  DEBUG_STREAM_POLLING_STATUSES = (DEBUG_BROADCAST_ACTIVE_STATUSES + %w[pending]).freeze
  UNKNOWN_TARGET_NAME = "Unknown target".freeze

  # Failure codes the classifier assigns from log evidence. It can apply them to a run
  # that produced every attempt, eval and completion row, so such a report has complete
  # results despite a failed status. Nothing recorded afterwards distinguishes that from
  # a genuine mid-run stop, so the backfill declines to guess and leaves them unset.
  PROVIDER_CLASSIFIED_FAILURE_CODES = %w[
    provider_model_unavailable
    provider_payment_required
    provider_auth_failed
    provider_rejected_request
    provider_rate_limited
    provider_service_unavailable
  ].freeze

  # Codes that assert incompleteness in their own right: the classifier saw a run end
  # without finishing. What went missing there may be a completion row or usable
  # timing rather than a probe result, so a full probe count cannot overturn it.
  # legacy_stale_processing is no longer written, but historical rows carry it.
  INCOMPLETE_ASSERTING_FAILURE_CODES = %w[
    scan_incomplete_results
    legacy_stale_processing
  ].freeze

  # Statuses a report can no longer move on from. Anything else is still being worked
  # on, and gets its completeness from the worker that finishes it -- classifying it
  # here would stamp a value that worker never revisits, and during an upgrade that
  # worker is still running the previous version.
  TERMINAL_STATUSES_FOR_BACKFILL = %i[completed failed stopped].freeze

  # Terminal states are reached from several places besides Reports::Process -- a stop,
  # the stale reaper, a launch failure, a failed variant child -- and each of those would
  # otherwise leave completeness unset forever. Recording it as the status changes means a
  # terminal report always carries the value, so every reader can simply check the column.
  # The ASR aggregate depends on that: it is one SQL round trip over many rows and cannot
  # call this model per row, so an unset column there would mean restating this whole rule
  # in SQL and keeping the two in step.
  #
  # Results are always persisted before the terminal transition (Reports::Process writes
  # them in the same transaction; a stop or reaper acts on a run that already produced
  # whatever it produced), so the evidence is complete by the time this reads it.
  before_save :record_result_completeness_on_terminal_status

  def record_result_completeness_on_terminal_status
    return unless will_save_change_to_status?
    # Reports::Process assigns the value from what it saw in the JSONL, which is richer
    # evidence than anything derivable afterwards -- never overwrite it.
    return if self[:result_completeness].present?
    return unless TERMINAL_STATUSES_FOR_BACKFILL.any? { |terminal| status == terminal.to_s }

    derived = compute_derived_result_completeness
    self[:result_completeness] = derived if derived.present?
  end

  def self.backfill_result_completeness!(batch_size: 1000)
    terminal = statuses.values_at(*TERMINAL_STATUSES_FOR_BACKFILL.map(&:to_s))

    where(result_completeness: nil, status: terminal).in_batches(of: batch_size) do |batch|
      batch.where(status: statuses[:completed]).update_all(result_completeness: "complete")

      unfinished = batch.where.not(status: statuses[:completed])
      counts = ProbeResult.where(report_id: unfinished.select(:id)).group(:report_id).count

      # Rows holding nothing are settled in one statement; only those holding results
      # need the plan compared against, and they are a small minority of terminal runs.
      unfinished.where.not(id: counts.keys).update_all(result_completeness: "none") if counts.any?
      next unfinished.update_all(result_completeness: "none") if counts.empty?

      unfinished.where(id: counts.keys).includes(scan: :probes).find_each do |report|
        completeness = report.completeness_from_evidence(counts[report.id].to_i)
        # nil means the evidence does not settle it; left NULL so a later run with a
        # recorded plan can classify it rather than freezing a guess.
        report.update_columns(result_completeness: completeness) if completeness
      end
    end
  end

  def self.ransackable_attributes(auth_object = nil)
    [ "company_id", "failure_code", "name", "created_at", "id", "status", "target_id", "updated_at", "uuid", "asr" ]
  end

  def self.ransackable_associations(auth_object = nil)
    [ "company", "target", "scan" ]
  end

  def historical_target
    historical_target_with_deleted
  end

  def historical_target_name
    historical_target&.name || UNKNOWN_TARGET_NAME
  end

  # Number of probes this run actually produced results for.
  def processed_scope
    probe_results.count
  end

  # Number of probes this run set out to execute, or nil when that is unknown.
  # Returned separately from processed_scope so callers can show the processed count
  # alone rather than assert a ratio they cannot support.
  #
  # Read from the plan recorded when the run was prepared, never from the scan's
  # current probe list: that list is mutable (an edit, or AutoUpdateScanProbesJob
  # adding probes afterwards), and a variant child executes mapped variants rather
  # than the scan's own probes. Reports created before the column have no recorded
  # plan, and no ratio is claimed for them.
  def planned_scope
    planned = planned_probe_count
    return nil if planned.nil? || planned.zero?

    planned
  end

  # The probe count this run will actually execute: mapped variants for a variant
  # child, the scan's selected probes otherwise.
  def planned_probe_count_for_run
    return variant_count if is_variant_report?

    scan&.probes&.count
  end

  # Best available evidence of the plan, used to judge completeness rather than to
  # display a ratio. Falls back to the scan's current probe list for rows predating
  # planned_probe_count: that list can have changed since the run, so it informs a
  # classification we would otherwise have to guess at, but never a figure shown to
  # the user -- planned_scope stays strict for that.
  def evidenced_planned_scope
    recorded = planned_probe_count
    return recorded unless recorded.nil? || recorded.zero?

    planned_probe_count_for_run
  end

  # The one rule both the live derivation and the backfill apply, so a report
  # classified as it finishes and one classified afterwards cannot disagree.
  #
  # Counting results against the plan is what makes a failure code unnecessary here:
  # a short result set is positive proof the run stopped early, and a full one proves
  # it produced everything asked of it -- including the provider-classified failures
  # that apply_terminal_provider_failure_metadata marks :failed on the strength of the
  # logs after every row was written. Only when there is no plan to compare against
  # does that ambiguity survive, and then nothing is claimed.
  def completeness_from_evidence(processed)
    return "none" if processed.zero?
    return "partial" if INCOMPLETE_ASSERTING_FAILURE_CODES.include?(failure_code)

    planned = evidenced_planned_scope
    return processed < planned ? "partial" : "complete" if planned.present? && planned.positive?
    return nil if PROVIDER_CLASSIFIED_FAILURE_CODES.include?(failure_code)

    "partial"
  end

  # Completeness inferred from what the run left behind, for rows with no stored value.
  # Memoized: the admin index calls several predicates per row, and each derivation
  # queries probe_results.
  def derived_result_completeness
    return @derived_result_completeness if defined?(@derived_result_completeness)

    @derived_result_completeness = compute_derived_result_completeness
  end

  def reload(*)
    remove_instance_variable(:@derived_result_completeness) if defined?(@derived_result_completeness)
    super
  end

  def compute_derived_result_completeness
    # Only terminal reports have a completeness to infer. A run still in flight may
    # yet produce results, and calling it "none" would be a claim we cannot make.
    return nil unless TERMINAL_STATUSES_FOR_BACKFILL.any? { |terminal| status == terminal.to_s }

    # A completed run is complete unless the plan recorded at launch says otherwise --
    # the same judgement Reports::Process makes, so a row an old processor left unset
    # cannot read differently from one written by the current code. Only the recorded
    # plan counts here, never the scan's current list: historical completed rows have
    # no recorded plan and must not be judged against a list that has grown since.
    if completed?
      planned = planned_probe_count.to_i
      return "complete" unless planned.positive?

      return processed_scope < planned ? "partial" : "complete"
    end

    completeness_from_evidence(processed_scope)
  end

  # Human-readable completed scope. Falls back to the processed count alone when the
  # planned scope is unknown, rather than asserting a ratio we cannot support.
  def processed_scope_summary
    processed = processed_scope
    planned = planned_scope
    # A variant child executes mapped threat variants and records one result per
    # variant, so calling those probes would misstate what was measured.
    unit = is_variant_report? ? "variant" : "probe"
    # A scan edited between attempts of a resumed run can leave the recorded plan below
    # what was processed, and "7 of 5 probes" states something that cannot be true. The
    # processed count is the fact we hold either way, so the ratio is simply dropped.
    return "#{processed} of #{planned} #{unit.pluralize}" if planned && processed <= planned

    "#{processed} #{unit.pluralize(processed)}"
  end

  def failed_with_reason?
    failed? && (failure_code.present? || failure_message.present?)
  end

  def user_failure_message
    return failure_message if failure_message.present?

    case failure_code
    when "provider_model_unavailable"
      "The provider rejected the configured model as unavailable. Update the target model, " \
        "revalidate the target, then rerun the scan."
    when "provider_payment_required"
      "The provider rejected the scan because billing or credits are required. Check the provider account, " \
        "then rerun the scan."
    when "provider_auth_failed"
      "The provider rejected the scan because authentication failed. Check the target credentials, " \
        "revalidate the target, then rerun the scan."
    when "provider_rejected_request"
      "The provider rejected the scan request. Review the target configuration, revalidate the target, " \
        "then rerun the scan."
    when "provider_rate_limited"
      "The provider rate limited the scan. Wait or reduce concurrency, then rerun the scan."
    when "provider_service_unavailable"
      "The provider is temporarily unavailable or returned an upstream error. Wait for the provider to recover, " \
        "revalidate the target, then rerun the scan."
    when "target_validation_failed"
      "The target is not ready for scanning. Revalidate the target, then rerun the scan."
    when "garak_runtime_error"
      "The scan runtime failed before results could be completed. Review the target configuration, then rerun the scan."
    else
      "The scan failed before results could be completed."
    end
  end

  def failure_title
    case failure_code
    when "provider_model_unavailable"
      "Provider model unavailable"
    when "provider_payment_required"
      "Provider billing required"
    when "provider_auth_failed"
      "Provider authentication failed"
    when "provider_rejected_request"
      "Provider rejected request"
    when "provider_rate_limited"
      "Provider rate limited"
    when "provider_service_unavailable"
      "Provider temporarily unavailable"
    when "target_validation_failed"
      "Target validation failed"
    when "garak_runtime_error"
      "Scan runtime failed"
    else
      "Scan failed"
    end
  end

  def failure_action
    case failure_code
    when "provider_model_unavailable"
      "Update the target model, revalidate the target, then rerun the scan."
    when "provider_payment_required"
      "Check provider billing or credits, then rerun the scan."
    when "provider_auth_failed"
      "Check API credentials, revalidate the target, then rerun the scan."
    when "provider_rejected_request"
      "Review the target configuration, revalidate the target, then rerun the scan."
    when "provider_rate_limited"
      "Wait or reduce scan concurrency, then rerun the scan."
    when "provider_service_unavailable"
      "Wait for the provider to recover, revalidate the target, then rerun the scan."
    when "target_validation_failed"
      "Fix target validation, then rerun the scan."
    else
      "Review the target configuration, then rerun the scan."
    end
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
    probe_results.sum(:passed)
  end

  # Cached accessor for total count - uses preloaded value if available, otherwise queries
  # Summed over probe_results because an attack is one prompt sent to the model, not one
  # detector's verdict on it. detector_results holds a row per detector, so pooling them
  # counted a single attack once per detector judging it: ASR then moved when a probe
  # gained a detector even though the target behaved identically, and the headline
  # disagreed with the probes tab and dashboard Average ASR, which both sum probe_results.
  def cached_total
    return read_attribute(:cached_total).to_i if has_attribute?(:cached_total)
    probe_results.sum(:total)
  end

  # Numeric ASR for charts, sorting and aggregates, which need a comparable number.
  #
  # Returns 0 when nothing was measurable, so it CANNOT distinguish "no attack
  # succeeded" from "no attacks were evaluated" -- never render it directly. Display
  # goes through #asr and ReportsHelper#asr_display, which keep those apart.
  def attack_success_rate
    total = cached_total
    passed = cached_passed
    return 0 if total == 0
    (passed.to_f / total * 100).round(2)
  end

  # The canonical reading every surface renders, and the only place the numerator and
  # denominator are chosen: detector_results, which is what ASR has always meant here
  # and what the aggregates use. Returning a figure rather than a Float keeps "nothing
  # succeeded" and "nothing was measurable" apart -- see Reports::AsrFigure.
  def asr
    Reports::AsrFigure.new(
      numerator: cached_passed,
      denominator: cached_total,
      partial: partial_results?
    )
  end

  # The most recent prior completed parent (non-variant) report of the same
  # scan + target — the run this report is compared against in the narrative
  # band. Scoped via scan.reports so it works without an ambient tenant (PDF
  # render). Variant child reports are not part of the run-over-run timeline,
  # so they have no "previous run" (and must never compare against their own
  # base).
  def previous_completed_report
    return nil if is_variant_report?

    scan.reports
        .parent_reports
        .completed
        # A finished run that dropped eval rows is completed but partial. Comparing
        # against it reports a movement that is an artefact of the missing work -- the
        # very comparison the partial notice tells the reader not to make. Rows written
        # before the column are complete by virtue of being completed, so NULL stays
        # eligible; <> alone would discard them, being unknown for NULL.
        .where("reports.result_completeness IS NULL OR reports.result_completeness <> 'partial'")
        .where(target_id: target_id)
        .where.not(id: id)
        .where("reports.created_at < ?", created_at)
        .order(created_at: :desc, id: :desc)
        .first
  end

  # Signed ASR delta vs the previous completed report (positive = ASR rose =
  # worse). nil when there is no prior completed report to compare against.
  # NOTE: calls attack_success_rate on self and on the prior report; each
  # falls back to two detector_results queries when not preloaded.
  # Multi-report callers should preload.
  # Movement against the previous run, or nil when there is nothing to compare.
  #
  # Computed from the figures rather than attack_success_rate, which collapses an
  # unmeasurable report to 0: subtracting that reported "50 pts vs last scan" beside an
  # ASR of "N/A" -- a movement away from a number that was never stated.
  def asr_delta_vs_previous
    prev = previous_completed_report
    return nil unless prev

    current_figure = asr
    previous_figure = prev.asr
    return nil unless current_figure.calculable? && previous_figure.calculable?

    (current_figure.percent - previous_figure.percent).round(2)
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

  def historical_target_with_deleted
    return if target_id.blank? || company_id.blank? || company.blank?

    ActsAsTenant.with_tenant(company) do
      Target.with_deleted.where(company_id: company_id).find_by(id: target_id)
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
