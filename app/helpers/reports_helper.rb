module ReportsHelper
  # Risk grade label boundaries, aligned to the ASR color bands (0...25, 25...50,
  # 50...75, 75+) so the grade word always matches the ASR number.
  RISK_GRADE_THRESHOLDS = [ [ 25, "Low" ], [ 50, "Medium" ], [ 75, "High" ] ].freeze

  VARIANT_INDUSTRY_EMOJIS = {
    "automotive" => "🚗",
    "finance" => "💰",
    "healthcare" => "🏥",
    "retail" => "🛍️",
    "technology" => "💻",
    "energy" => "⚡",
    "education" => "🎓",
    "government" => "🏛️",
    "manufacturing" => "🏭"
  }.freeze

  def activity_stream_active_status_for_report?(report)
    return false if report.blank?

    (Report::DEBUG_BROADCAST_ACTIVE_STATUSES + %w[pending]).uniq.include?(report.status.to_s)
  end

  def show_activity_stream_for_report?(report, params:, user:, pdf_mode: false)
    return false if pdf_mode
    return false if user.blank?
    return false if report.blank?

    activity_stream_active_status_for_report?(report) || debug_param_enabled?(params)
  end

  # Get CSS classes for success rate coloring
  def success_rate_classes(rate)
    case rate
    when 80..100
      "text-red-400"
    when 50...80
      "text-orange-400"
    when 25...50
      "text-yellow-400"
    else
      "text-emerald-400"
    end
  end

  # Get background color class for max score pill
  def max_score_bg_color(score)
    case score
    when 90..100
      "bg-red-500/25"
    when 75...90
      "bg-amber-400/25"
    when 50...75
      "bg-blue-500/25"
    else
      "bg-gray-800/30"
    end
  end

  # Get text color class for max score value
  def max_score_text_color(score)
    case score
    when 90..100
      "text-red-600"
    when 75...90
      "text-amber-400"
    when 50...75
      "text-blue-400"
    else
      "text-zinc-300"
    end
  end

  # Get CSS classes for variant pill based on test results
  def variant_pill_classes(subindustry_id, probe_results_map)
    probe_result = probe_results_map[subindustry_id]

    if probe_result.nil?
      "bg-zinc-800 text-zinc-500" # Gray - not run
    elsif probe_result.any_detector_passed
      "bg-red-950 text-red-400" # Red - ran and detected (attack passed)
    else
      "bg-purple-950 text-purple-400" # Purple - ran but not detected (attack failed/blocked)
    end
  end

  # Get CSS classes for variant category text based on whether any subindustry was tested
  def variant_category_text_classes(subindustries, probe_results_map)
    # White if ANY subindustry was tested, grey otherwise
    tested = subindustries.any? { |sub| probe_results_map[sub.id].present? }
    tested ? "text-white" : "text-[#71717a]"
  end

  # Industry tag for a variant probe result's threat_variant.
  # Returns nil for non-variant results; emoji falls back to 🏢 for unmapped industries.
  def variant_industry_tag(threat_variant)
    return nil if threat_variant.blank?

    subindustry = threat_variant.threat_variant_subindustry
    industry = subindustry&.threat_variant_industry
    return nil if industry.blank? || subindustry.blank?

    {
      emoji: VARIANT_INDUSTRY_EMOJIS[industry.name.downcase] || "🏢",
      industry: industry.name,
      subindustry: subindustry.name
    }
  end

  # 4-tier risk grade label for an ASR percentage. nil when asr is nil.
  def report_risk_grade_label(asr)
    return nil if asr.nil?
    RISK_GRADE_THRESHOLDS.each { |max, label| return label if asr.to_f < max }
    "Critical"
  end

  # Light-theme pill classes for the risk grade chip on the (light) customer
  # report band, aligned to the same 4 thresholds. nil when asr is nil.
  def report_risk_grade_classes(asr)
    return nil if asr.nil?
    case asr.to_f
    when 0...25 then "bg-zinc-100 text-zinc-700"
    when 25...50 then "bg-yellow-100 text-yellow-800"
    when 50...75 then "bg-orange-100 text-orange-800"
    else "bg-red-100 text-red-800"
    end
  end

  # Format report duration as human-readable text
  def formatted_duration(report)
    return "N/A" unless report.start_time && report.end_time
    distance_of_time_in_words(report.start_time, report.end_time, include_seconds: true)
  end

  # Per-prompt result for an attempt hash from probe_result.attempts.
  # succeeded: true (Attack Successful) / false (Blocked) / nil (unknown — legacy
  # attempt ingested before detector_results was captured).
  def attempt_result(attempt)
    {
      succeeded: attempt["attack_succeeded"],
      score_percentage: attempt.dig("notes", "score_percentage")
    }
  end

  # Format token counts for display
  # Returns nil if both counts are 0 (old reports without token data)
  # @param input_tokens [Integer] Number of input tokens
  # @param output_tokens [Integer] Number of output tokens
  # @return [String, nil] Formatted string or nil if no tokens
  def format_token_count(input_tokens, output_tokens)
    return nil if input_tokens.to_i == 0 && output_tokens.to_i == 0
    "#{number_with_delimiter(input_tokens)} in / #{number_with_delimiter(output_tokens)} out"
  end

  private

  def debug_param_enabled?(params)
    value = params[:debug] if params.respond_to?(:[])
    value ||= params["debug"] if params.respond_to?(:[])

    value.to_s == "true"
  end
end
