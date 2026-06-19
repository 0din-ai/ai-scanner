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
