# frozen_string_literal: true

class BroadcastRunningStatsJob < ApplicationJob
  queue_as :default

  # Debounce rapid status changes per company.
  # Use company_id in key to allow parallel broadcasts for different companies.
  limits_concurrency to: 1, key: ->(company_id) { "broadcast_running_stats:#{company_id}" }, on_conflict: :discard

  # Broadcasts running report stats for a specific company and global totals.
  #
  # @param company_id [Integer] The company to broadcast stats for (required).
  def perform(company_id)
    broadcast_company_stats(company_id)
    broadcast_global_stats
  end

  private

  def broadcast_company_stats(company_id)
    stats = Reports::RunningStats.write_company(company_id)

    Turbo::StreamsChannel.broadcast_replace_to(
      stream_name_for(company_id),
      target: "system-status-company",
      partial: "application/system_status_company",
      locals: { stats: stats }
    )
  end

  def broadcast_global_stats
    stats = Reports::RunningStats.write_global

    Turbo::StreamsChannel.broadcast_replace_to(
      stream_name_for(:global),
      target: "system-status-global",
      partial: "application/system_status_global",
      locals: { stats: stats }
    )
  end

  def calculate_company_stats(company_id)
    Reports::RunningStats.company(company_id)
  end

  def calculate_global_stats
    Reports::RunningStats.global
  end

  def cache_key_for(identifier)
    Reports::RunningStats.cache_key_for(identifier)
  end

  def stream_name_for(identifier)
    identifier == :global ? "system-status:global" : "system-status:company_#{identifier}"
  end
end
