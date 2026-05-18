class Scan < ApplicationRecord
    include ScanVariantDefaults

    acts_as_tenant :company

    # Projection period for monthly token estimates (in days)
    PROJECTION_PERIOD_DAYS = 30
    OUTPUT_MULTIPLIER = 2

    class IceCubeScheduleCoder
      def self.dump(schedule)
        return unless schedule.present?

        if schedule.is_a?(IceCube::Rule)
          schedule.to_hash
        elsif schedule.is_a?(String)
          IceCube::Rule.from_hash(JSON.parse(schedule)).to_hash
        end
      end

      def self.load(json)
        return unless json.present?

        json = JSON.parse(json) if json.is_a?(String)
        IceCube::Rule.from_hash(json)
      end
    end

    has_and_belongs_to_many :targets
    has_and_belongs_to_many :probes
    has_many :reports, dependent: :destroy
    belongs_to :output_server, optional: true

    validates :uuid, presence: true, uniqueness: true
    validates :targets, presence: true
    validates :probes, presence: true
    validates :avg_successful_attacks, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
    validate :auto_update_flags_have_corresponding_probes
    validate :variants_require_eligible_probe

    serialize :recurrence, coder: IceCubeScheduleCoder

    before_validation :generate_uuid, :update_next_scheduled_run
    before_save :check_probe_changes
    after_create do
      create_reports unless scheduled?
    end

    scope :due_to_run, -> { where("next_scheduled_run <= ?", Time.now.utc) }
    scope :scheduled, -> { where.not(recurrence: nil) }
    scope :unscheduled, -> { where(recurrence: nil) }
    scope :auto_updating_generic, -> { where(auto_update_generic: true) }
    scope :auto_updating_cm, -> { where(auto_update_cm: true) }
    scope :auto_updating_hp, -> { where(auto_update_hp: true) }

    def self.ransackable_attributes(auth_object = nil)
      [ "company_id", "name", "created_at", "id", "updated_at", "uuid", "avg_successful_attacks", "reports_count" ]
    end

    def self.ransackable_associations(auth_object = nil)
      [ "company", "targets" ]
    end

    def rerun
      create_reports
    end

    def update_next_scheduled_run
      if recurrence.blank?
        self.next_scheduled_run = nil
      else
        schedule = IceCube::Schedule.new(Time.now.utc)
        schedule.add_recurrence_rule(recurrence)
        self.next_scheduled_run = schedule.next_occurrence.beginning_of_minute
      end
    end

    def scheduled?
      recurrence.present?
    end


    def calculate_avg_successful_attacks
      return 0.0 if reports.completed.empty?

      # Single SQL query with GROUP BY to avoid N+1 queries
      # Aggregates passed/total per report, then calculates attack rate
      # Uses LEFT JOIN to include reports even if they have no detector_results
      results = reports.completed
        .left_joins(:detector_results)
        .group("reports.id")
        .select(
          "reports.id",
          "COALESCE(SUM(detector_results.passed), 0) as total_passed",
          "COALESCE(SUM(detector_results.total), 0) as total_count"
        )

      return 0.0 if results.empty?

      attack_rates = results.map do |result|
        total = result.total_count.to_i
        passed = result.total_passed.to_i
        total > 0 ? (passed.to_f / total * 100) : 0.0
      end

      (attack_rates.sum / attack_rates.size).round(2)
    end

    def update_avg_successful_attacks!
      update_column(:avg_successful_attacks, calculate_avg_successful_attacks)
    end

    def auto_updating_categories
      categories = []
      categories << "Generic" if auto_update_generic?
      categories << "CM" if auto_update_cm?
      categories << "HP" if auto_update_hp?
      categories
    end

    def derived_status
      return nil if reports.empty?
      return "running" if reports.where(status: [ :running, :starting, :processing ]).any?

      reports.order(created_at: :desc, id: :desc).pick(:status)
    end

  # Token usage estimation methods
  # Note: Only INPUT tokens can be estimated (from probe prompts)
  # Output tokens are unpredictable as they depend on model responses

  # Returns the projected input tokens per scan based on selected probes
  # Memoized to avoid repeated queries when called multiple times (e.g., in monthly_token_projection)
  # @return [Integer] Sum of input_tokens from all selected probes
  def projected_input_tokens
    @projected_input_tokens ||= probes.sum(:input_tokens)
  end

  # Returns the monthly token projection for scheduled scans
  # Uses IceCube to count actual scheduled occurrences in the projection period
  # @return [Hash, nil] { runs: Integer, tokens: Integer } or nil if not scheduled
  def monthly_token_projection
    return nil unless scheduled?

    schedule = IceCube::Schedule.new(Time.current)
    schedule.add_recurrence_rule(recurrence)
    runs = schedule.occurrences_between(
      Time.current,
      PROJECTION_PERIOD_DAYS.days.from_now
    ).count

    {
      runs: runs,
      tokens: runs * projected_input_tokens
    }
  end

  # Estimate run time based on targets' token processing rates
  # Returns nil if no API targets with measured rates
  # @return [Hash, nil] { seconds: Integer, formatted: String, parallel_limit: Integer, unmeasured_targets: Integer }
  def estimated_run_time
    api_targets = targets.where(target_type: :api).where.not(tokens_per_second: nil)
    return nil if api_targets.empty?

    input_tokens = projected_input_tokens
    return nil if input_tokens.zero?

    # Calculate time for each target (seconds)
    # Multiply by OUTPUT_MULTIPLIER to account for unpredictable output token generation
    estimated_total_tokens = input_tokens * OUTPUT_MULTIPLIER
    target_times = api_targets.map { |t| estimated_total_tokens.to_f / t.tokens_per_second }

    # With parallelism: total sequential time / parallel limit
    parallel_limit = SettingsService.parallel_scans_limit
    estimated_seconds = (target_times.sum / parallel_limit).round

    # Count unmeasured API targets
    unmeasured = targets.where(target_type: :api, tokens_per_second: nil).count

    {
      seconds: estimated_seconds,
      formatted: format_duration(estimated_seconds),
      parallel_limit: parallel_limit,
      unmeasured_targets: unmeasured
    }
  end

  # Returns actual token usage averages from completed reports
  # Uses single SQL query with COUNT and SUM aggregation to avoid N+1 queries
  # @return [Hash, nil] { input: Float, output: Float, count: Integer } or nil if no reports
  def actual_token_averages
    completed = reports.completed
    return nil if completed.empty?

    # Single query: filter to reports with token data AND aggregate
    # Only counts reports that have probe_results with tokens > 0
    totals = completed.joins(:probe_results)
                      .where("probe_results.input_tokens > 0 OR probe_results.output_tokens > 0")
                      .select("COUNT(DISTINCT reports.id) as report_count,
                               SUM(probe_results.input_tokens) as total_input,
                               SUM(probe_results.output_tokens) as total_output")
                      .take

    count = totals.report_count.to_i
    return nil if count.zero?

    {
      input: (totals.total_input.to_f / count).round,
      output: (totals.total_output.to_f / count).round,
      count: count
    }
  end

    private

    def check_probe_changes
      return unless persisted?

      current_db_ids = self.class.connection.select_values(
        self.class.sanitize_sql_array(
          [ "SELECT probe_id FROM probes_scans WHERE scan_id = ? ORDER BY probe_id", id ]
        )
      )
      new_ids = probe_ids.sort

      return if current_db_ids == new_ids

      old_ids = current_db_ids
      all_ids = (old_ids + new_ids).uniq

      return if all_ids.empty?

      probe_names_by_id = Probe.where(id: all_ids).pluck(:id, :name).to_h

      old_probe_names = old_ids.map { |id| probe_names_by_id[id] }.compact
      new_probe_names = new_ids.map { |id| probe_names_by_id[id] }.compact

      old_by_category = group_probes_by_category(old_probe_names)
      new_by_category = group_probes_by_category(new_probe_names)

      self.auto_update_generic = false if auto_update_generic? &&
        old_by_category[:generic].sort != new_by_category[:generic].sort
      self.auto_update_cm = false if auto_update_cm? &&
        old_by_category[:cm].sort != new_by_category[:cm].sort
      self.auto_update_hp = false if auto_update_hp? &&
        old_by_category[:hp].sort != new_by_category[:hp].sort
    end

    def group_probes_by_category(probe_names)
      {
        generic: probe_names.reject { |n| n.end_with?("CM", "HP") },
        cm: probe_names.select { |n| n.end_with?("CM") },
        hp: probe_names.select { |n| n.end_with?("HP") }
      }
    end

    def auto_update_flags_have_corresponding_probes
      # Skip validation if no auto-update flags are enabled (performance optimization)
      return unless auto_update_generic? || auto_update_cm? || auto_update_hp?

      # Single query to fetch all probe names and categorize them in Ruby
      probe_names = probes.pluck(:name)
      categorized = group_probes_by_category(probe_names)

      if auto_update_generic? && categorized[:generic].empty?
        errors.add(:auto_update_generic, "cannot be enabled without generic probes")
      end

      if auto_update_cm? && categorized[:cm].empty?
        errors.add(:auto_update_cm, "cannot be enabled without CM probes")
      end

      if auto_update_hp? && categorized[:hp].empty?
        errors.add(:auto_update_hp, "cannot be enabled without HP probes")
      end
    end

    def variants_require_eligible_probe
      return if threat_variant_subindustries.empty?

      probe_records = probes.to_a
      ActiveRecord::Associations::Preloader.new(records: probe_records, associations: [ :detector ]).call
      return if probe_records.any?(&:variant_eligible?)

      errors.add(:base, "Threat variants require at least one copyright or illicit-substance probe")
    end

    def generate_uuid
      self.uuid = SecureRandom.uuid unless self.uuid
    end

    def format_duration(seconds)
      return "0m" if seconds <= 0

      days = seconds / 86400
      hours = (seconds % 86400) / 3600
      minutes = (seconds % 3600) / 60

      parts = []
      parts << "#{days}d" if days > 0
      parts << "#{hours}h" if hours > 0
      parts << "#{minutes}m" if minutes > 0 || parts.empty?
      parts.join(" ")
    end

    def create_reports
      unless company.scan_allowed?
        errors.add(:base, "Weekly scan quota reached (#{company.weekly_scan_count}/#{company.scans_per_week_limit}). Resets next Monday.")
        return []
      end

      created_reports = targets.map do |target|
        reports.create(target: target, company: company)
      end

      # Trigger immediate scan start instead of waiting for the next scheduled job run
      # This provides instant feedback while still respecting slot limits and atomic claiming
      StartPendingScansJob.perform_later if created_reports.any?(&:persisted?)

      created_reports
    end
end
