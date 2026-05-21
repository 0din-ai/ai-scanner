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

  # Variant methods (variants_by_industry, variant_probe_results, etc.)
  # are provided by the engine decorator override when variant features are enabled.
end
