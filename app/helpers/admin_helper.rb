# frozen_string_literal: true

module AdminHelper
  # Status tag helper for admin views
  # Usage: status_tag("Active", :ok) or status_tag("Pending")
  # Whether there is anything to open: a finished scan, or a run that stopped early
  # but retained usable evidence. Gating the Details and PDF links on completed?
  # alone hides exactly the partial reports the new notice exists to explain.
  def report_has_viewable_results?(report)
    return true if report.completed?

    # Read once: each predicate re-derives completeness for an unclassified row, and
    # every derivation queries probe_results. This runs on every row of the index.
    completeness = report.result_completeness
    return true if completeness == "partial" || completeness == "complete"

    # Completeness is left unresolved when there is no plan to compare the results
    # against. They are real either way, so they stay reachable.
    completeness.nil? && report.probe_results.exists?
  end

  # Renders the report's lifecycle and, when it applies, its result completeness.
  # They are shown as two tags because they answer different questions: how the run
  # ended, and whether what it left behind is usable evidence.
  def report_lifecycle_tags(report)
    tags = [ status_tag(report.status) ]

    if report.partial_results?
      tags << status_tag("partial results", :warning)
    end

    safe_join(tags, " ")
  end

  def status_tag(text, status = nil)
    # Map status to CSS classes
    status_classes = case status
    when :ok, :yes, "ok", "yes", true
      "bg-lime-950 text-lime-400 dark:bg-lime-950 dark:text-lime-400"
    when :warning, :warn, "warning", "warn"
      "bg-zinc-800 text-zinc-400 dark:bg-zinc-800 dark:text-zinc-400"
    when :error, :no, "error", "no", false
      "bg-red-950 text-red-400 dark:bg-red-950 dark:text-red-400"
    else
      # Auto-detect based on text content if no status provided
      case text.to_s.downcase
      when "completed", "success", "active", "yes", "ok", "enabled", "passed"
        "bg-lime-950 text-lime-400 dark:bg-lime-950 dark:text-lime-400"
      when "pending", "processing", "in_progress", "in progress", "running", "interrupted"
        "bg-zinc-800 text-zinc-400 dark:bg-zinc-800 dark:text-zinc-400"
      when "failed", "error", "no", "disabled", "deleted", "cancelled"
        "bg-red-950 text-red-400 dark:bg-red-950 dark:text-red-400"
      when "warning", "paused", "stopped"
        "bg-zinc-800 text-zinc-400 dark:bg-zinc-800 dark:text-zinc-400"
      else
        "bg-zinc-800 text-zinc-400 dark:bg-zinc-800 dark:text-zinc-400"
      end
    end

    content_tag(:span, text.to_s.humanize, class: "inline-flex items-center px-2.5 py-0.5 rounded-md text-xs font-medium #{status_classes}")
  end

  # Menu system helpers

  def current_menu
    @current_menu ||= AdminMenu.build(self)
  end

  def current_menu_item?(item)
    item.current?(controller_path, action_name) || item.url_matches?(request.path)
  end

  # Page title helpers

  def html_head_site_title
    separator = "-"
    "#{@page_title || page_title} #{separator} #{site_title}"
  end

  def site_title
    "Scanner"
  end

  def page_title
    @page_title || controller_name.titleize
  end
end
