module ScanHelper
  def scan_format_recurrence_schedule(recurrence)
    return "Not scheduled" unless recurrence.present?

    rule_type = extract_rule_type(recurrence)

    case rule_type
    when "hourly"
      format_hourly_schedule(recurrence)
    when "daily"
      format_daily_schedule(recurrence)
    when "weekly"
      format_weekly_schedule(recurrence)
    when "monthly"
      format_monthly_schedule(recurrence)
    else
      "Unknown schedule type"
    end
  end

  # Probe ids that actually have threat variants — loaded once per request so the
  # probe-selection form (≈935 probes) can flag variant-eligibility without N+1.
  def variant_eligible_probe_ids
    @variant_eligible_probe_ids ||= ThreatVariant.distinct.pluck(:probe_id).to_set
  end

  private

  def extract_rule_type(recurrence)
    recurrence.class.name.demodulize.gsub("Rule", "").downcase
  end

  def format_hourly_schedule(recurrence)
    minute = extract_validation_value(recurrence, :minute_of_hour, 0)

    if minute == 0
      "Every hour on the hour"
    else
      "Every hour at #{minute} #{minute == 1 ? 'minute' : 'minutes'} past"
    end
  end

  def format_daily_schedule(recurrence)
    time_str = format_time_from_recurrence(recurrence)
    "Daily#{time_str}"
  end

  def format_weekly_schedule(recurrence)
    days_text = format_weekly_days(recurrence)
    time_str = format_time_from_recurrence(recurrence)
    "Weekly#{days_text}#{time_str}"
  end

  def format_monthly_schedule(recurrence)
    utc_day = extract_validation_value(recurrence, :day_of_month, 1)
    utc_hour = extract_validation_value(recurrence, :hour_of_day, 0)
    utc_minute = extract_validation_value(recurrence, :minute_of_hour, 0)
    local_day = convert_utc_day_of_month_to_user_timezone(utc_day, utc_hour, utc_minute)
    time_str = format_time_from_recurrence(recurrence)
    "Monthly on the #{local_day.ordinalize}#{time_str}"
  end

  def format_weekly_days(recurrence)
    day_validations = recurrence.validations[:day]
    return "" unless day_validations.present?

    day_validations = [ day_validations ] unless day_validations.is_a?(Array)

    # Convert UTC days to user timezone days
    utc_hour = extract_validation_value(recurrence, :hour_of_day, 0)
    utc_minute = extract_validation_value(recurrence, :minute_of_hour, 0)

    user_timezone_days = day_validations.map do |day_validation|
      convert_utc_day_to_user_timezone(day_validation.value, utc_hour, utc_minute)
    end.uniq.sort

    day_names = user_timezone_days.map do |day_num|
      Date::DAYNAMES[day_num % 7] + "s"
    end.join(", ")

    " on #{day_names}"
  end

  def format_time_from_recurrence(recurrence)
    hour_validation = recurrence.validations[:hour_of_day]&.first
    minute_validation = recurrence.validations[:minute_of_hour]&.first

    return "" unless hour_validation || minute_validation

    utc_hour = hour_validation&.value || 0
    utc_minute = minute_validation&.value || 0

    local_time = convert_utc_time_to_user_timezone(utc_hour, utc_minute)
    time_str = format_time_12h(local_time.hour, local_time.min)

    " at #{time_str}"
  end

  def extract_validation_value(recurrence, validation_key, default = nil)
    recurrence.validations[validation_key]&.first&.value || default
  end

  def convert_utc_time_to_user_timezone(utc_hour, utc_minute)
    utc_time = Time.now.utc.beginning_of_day + utc_hour.hours + utc_minute.minutes
    utc_time.in_time_zone(Time.zone)
  end

  def convert_utc_day_of_month_to_user_timezone(utc_day, utc_hour, utc_minute)
    # Use offset arithmetic (matching JS convertDayOfMonthFromUTC) to avoid month-boundary crossing
    offset_minutes = Time.zone.now.utc_offset / 60
    total_minutes = utc_hour * 60 + utc_minute + offset_minutes
    day_shift = if total_minutes < 0 then -1
    elsif total_minutes >= 1440 then 1
    else 0
    end
    (utc_day + day_shift).clamp(1, 28)
  end

  def convert_utc_day_to_user_timezone(utc_day, utc_hour, utc_minute)
    base_date = Time.now.utc.beginning_of_week(:sunday)
    utc_time = base_date + utc_day.days + utc_hour.hours + utc_minute.minutes
    local_time = utc_time.in_time_zone(Time.zone)
    local_time.wday
  end

  def format_time_12h(hour, minute)
    am_pm = hour >= 12 ? "PM" : "AM"
    display_hour = hour % 12
    display_hour = 12 if display_hour == 0
    "#{display_hour}:#{minute.to_s.rjust(2, '0')} #{am_pm}"
  end

  def detector_icon(short_name)
    case short_name
    when /crystal.*meth/i, /cm/i then "icon-beaker"
    when /harry.*potter/i, /hp/i then "icon-book-open"
    else "icon-search"
    end
  end

  def detector_color(short_name)
    case short_name
    when /crystal.*meth/i, /cm/i then "red"
    when /harry.*potter/i, /hp/i then "violet"
    else "blue"
    end
  end
end
