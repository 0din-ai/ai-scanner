class ReportDecorator < SimpleDelegator
  def target_name
    __getobj__.historical_target_name
  end

  def probe_results
    @probe_results ||= __getobj__.probe_results.order(passed: :desc).includes(:probe, :detector).to_a
  end

  def scan_duration
    return "N/A" if !__getobj__.start_time || !__getobj__.end_time

    ActiveSupport::Duration.build((__getobj__.end_time - __getobj__.start_time).round).inspect
  end

  def probe_count
    probe_results.size
  end

  # Total per-detector evaluations across the run (Σ detector_results.total).
  # Reconciles with probe_count in the Detector Statistics header: each probe runs
  # multiple prompts and each prompt can be scored by multiple detectors, so this
  # exceeds the probe count. Counts evaluation events, not distinct prompts (a prompt
  # scored by two detectors is counted once per detector).
  def detector_evaluation_count
    # `total` is a nullable column; SUM returns nil when rows exist but every total
    # is NULL, so coerce to 0 to keep the reconciling line well-formed.
    __getobj__.detector_results.sum(:total) || 0
  end

  # Highest-ASR probe results for the narrative band's "Top findings" list.
  # Reuses the already-loaded probe_results array. A "finding" is a probe the
  # report treats as vulnerable — keyed on any_detector_passed (consistent with
  # the VULNERABLE badge), so multi-detector probes bypassed with a zero
  # canonical `passed` count still count. Skip zero-attempt and defended rows.
  def top_findings(limit: 3)
    probe_results
      .select { |pr| pr.total.to_i.positive? && pr.any_detector_passed }
      .sort_by { |pr| -pr.asr_percentage.to_f }
      .first(limit)
      .map { |pr| { name: pr.probe&.name, asr: pr.asr_percentage } }
  end

  # Variant methods (variants_by_industry, variant_probe_results, etc.)
  # are provided by the engine decorator override when variant features are enabled.
end
