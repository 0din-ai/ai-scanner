module ReportsHelper
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

  # Format report duration as human-readable text
  def formatted_duration(report)
    return "N/A" unless report.start_time && report.end_time
    distance_of_time_in_words(report.start_time, report.end_time, include_seconds: true)
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
end
