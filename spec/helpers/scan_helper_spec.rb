require 'rails_helper'

RSpec.describe ScanHelper, type: :helper do
  describe '#scan_format_recurrence_schedule' do
    before do
      allow(Time).to receive(:zone).and_return(ActiveSupport::TimeZone["Eastern Time (US & Canada)"])
      travel_to Time.utc(2026, 1, 15, 12, 0, 0) # Winter date to ensure EST (UTC-5), not EDT
    end

    context 'when recurrence is nil' do
      it 'returns "Not scheduled"' do
        expect(helper.scan_format_recurrence_schedule(nil)).to eq("Not scheduled")
      end
    end

    context 'with daily recurrence' do
      it 'converts UTC time to user timezone for display' do
        rule = IceCube::Rule.daily.hour_of_day(12).minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Daily at 7:00 AM") # EST (UTC-5)
      end

      it 'handles PM times correctly' do
        rule = IceCube::Rule.daily.hour_of_day(20).minute_of_hour(30)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Daily at 3:30 PM") # EST (UTC-5)
      end
    end

    context 'with weekly recurrence' do
      it 'converts UTC time and adjusts days when timezone conversion changes the day' do
        rule = IceCube::Rule.weekly.day(:monday).hour_of_day(2).minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Weekly on Sundays at 9:00 PM") # EST (UTC-5)
      end

      it 'handles multiple days correctly' do
        rule = IceCube::Rule.weekly.day(:monday, :wednesday).hour_of_day(16).minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Weekly on Mondays, Wednesdays at 11:00 AM") # EST (UTC-5)
      end
    end

    context 'with monthly recurrence' do
      it 'formats monthly schedule with day and time' do
        rule = IceCube::Rule.monthly.day_of_month(15).hour_of_day(14).minute_of_hour(30)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Monthly on the 15th at 9:30 AM") # EST (UTC-5)
      end

      it 'handles 1st of month' do
        rule = IceCube::Rule.monthly.day_of_month(1).hour_of_day(12).minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Monthly on the 1st at 7:00 AM")
      end

      it 'handles 2nd of month' do
        rule = IceCube::Rule.monthly.day_of_month(2).hour_of_day(12).minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Monthly on the 2nd at 7:00 AM")
      end

      it 'handles 3rd of month' do
        rule = IceCube::Rule.monthly.day_of_month(3).hour_of_day(12).minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Monthly on the 3rd at 7:00 AM")
      end

      it 'handles special ordinals (11th, 12th, 13th)' do
        [ 11, 12, 13 ].each do |day|
          rule = IceCube::Rule.monthly.day_of_month(day).hour_of_day(12).minute_of_hour(0)

          result = helper.scan_format_recurrence_schedule(rule)

          expect(result).to eq("Monthly on the #{day}th at 7:00 AM")
        end
      end

      it 'defaults to 1st when day_of_month validation is absent' do
        rule = IceCube::Rule.monthly.hour_of_day(12).minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Monthly on the 1st at 7:00 AM")
      end

      it 'handles monthly without time validation' do
        rule = IceCube::Rule.monthly.day_of_month(15)

        result = helper.scan_format_recurrence_schedule(rule)

        # Without time validation, UTC hour defaults to 0 (midnight UTC)
        # In EST (UTC-5), midnight UTC = 7 PM previous day, so day shifts from 15 to 14
        expect(result).to eq("Monthly on the 14th")
      end

      it 'clamps day=1 at midnight UTC in western timezone instead of rolling to previous month' do
        rule = IceCube::Rule.monthly.day_of_month(1).hour_of_day(0).minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        # In EST (UTC-5), midnight UTC = 7 PM Dec 31 — must clamp to 1, not show 31st
        expect(result).to eq("Monthly on the 1st at 7:00 PM")
      end
    end

    context 'with hourly recurrence' do
      it 'shows hourly at exact hour' do
        rule = IceCube::Rule.hourly.minute_of_hour(0)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Every hour on the hour")
      end

      it 'shows hourly with minutes past' do
        rule = IceCube::Rule.hourly.minute_of_hour(15)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Every hour at 15 minutes past")
      end

      it 'handles singular minute correctly' do
        rule = IceCube::Rule.hourly.minute_of_hour(1)

        result = helper.scan_format_recurrence_schedule(rule)

        expect(result).to eq("Every hour at 1 minute past")
      end
    end
  end

  describe '#detector_icon' do
    it 'returns beaker for Crystal Meth detector' do
      expect(helper.send(:detector_icon, "CrystalMethScore")).to eq("icon-beaker")
    end

    it 'returns book-open for Harry Potter detector' do
      expect(helper.send(:detector_icon, "CopyRightScoreHarryPotterChapterOne")).to eq("icon-book-open")
    end

    it 'returns search as fallback for unknown detectors' do
      expect(helper.send(:detector_icon, "SomeUnknownDetector")).to eq("icon-search")
    end
  end

  describe '#variant_eligible_probe_ids' do
    it 'returns the ids of probes that have threat variants, memoized' do
      with_variant = create(:probe)
      without_variant = create(:probe)
      create(:threat_variant, probe: with_variant)

      expect(ThreatVariant).to receive(:distinct).once.and_call_original

      expect(helper.variant_eligible_probe_ids).to include(with_variant.id)
      expect(helper.variant_eligible_probe_ids).not_to include(without_variant.id)
      expect(helper.variant_eligible_probe_ids).to be_a(Set)
    end
  end

  describe '#detector_color' do
    it 'returns red for Crystal Meth detector' do
      expect(helper.send(:detector_color, "CrystalMethScore")).to eq("red")
    end

    it 'returns violet for Harry Potter detector' do
      expect(helper.send(:detector_color, "CopyRightScoreHarryPotterChapterOne")).to eq("violet")
    end

    it 'returns blue as fallback for unknown detectors' do
      expect(helper.send(:detector_color, "SomeUnknownDetector")).to eq("blue")
    end
  end
end
