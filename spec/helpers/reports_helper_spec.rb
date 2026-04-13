require 'rails_helper'

RSpec.describe ReportsHelper, type: :helper do
  describe '#success_rate_classes' do
    context 'when rate is 80-100 (critical)' do
      it 'returns red text class for 100%' do
        expect(helper.success_rate_classes(100)).to eq('text-red-400')
      end

      it 'returns red text class for 80%' do
        expect(helper.success_rate_classes(80)).to eq('text-red-400')
      end

      it 'returns red text class for 90%' do
        expect(helper.success_rate_classes(90)).to eq('text-red-400')
      end
    end

    context 'when rate is 50-79 (high)' do
      it 'returns orange text class for 79%' do
        expect(helper.success_rate_classes(79)).to eq('text-orange-400')
      end

      it 'returns orange text class for 50%' do
        expect(helper.success_rate_classes(50)).to eq('text-orange-400')
      end

      it 'returns orange text class for 65%' do
        expect(helper.success_rate_classes(65)).to eq('text-orange-400')
      end
    end

    context 'when rate is 25-49 (medium)' do
      it 'returns yellow text class for 49%' do
        expect(helper.success_rate_classes(49)).to eq('text-yellow-400')
      end

      it 'returns yellow text class for 25%' do
        expect(helper.success_rate_classes(25)).to eq('text-yellow-400')
      end

      it 'returns yellow text class for 35%' do
        expect(helper.success_rate_classes(35)).to eq('text-yellow-400')
      end
    end

    context 'when rate is 0-24 (low)' do
      it 'returns emerald text class for 24%' do
        expect(helper.success_rate_classes(24)).to eq('text-emerald-400')
      end

      it 'returns emerald text class for 0%' do
        expect(helper.success_rate_classes(0)).to eq('text-emerald-400')
      end

      it 'returns emerald text class for 10%' do
        expect(helper.success_rate_classes(10)).to eq('text-emerald-400')
      end
    end
  end

  describe '#max_score_bg_color' do
    context 'when score is 90-100 (critical)' do
      it 'returns red background for 100%' do
        expect(helper.max_score_bg_color(100)).to eq('bg-red-500/25')
      end

      it 'returns red background for 90%' do
        expect(helper.max_score_bg_color(90)).to eq('bg-red-500/25')
      end
    end

    context 'when score is 75-89 (high)' do
      it 'returns amber background for 89%' do
        expect(helper.max_score_bg_color(89)).to eq('bg-amber-400/25')
      end

      it 'returns amber background for 75%' do
        expect(helper.max_score_bg_color(75)).to eq('bg-amber-400/25')
      end
    end

    context 'when score is 50-74 (medium)' do
      it 'returns blue background for 74%' do
        expect(helper.max_score_bg_color(74)).to eq('bg-blue-500/25')
      end

      it 'returns blue background for 50%' do
        expect(helper.max_score_bg_color(50)).to eq('bg-blue-500/25')
      end
    end

    context 'when score is 0-49 (low)' do
      it 'returns gray background for 49%' do
        expect(helper.max_score_bg_color(49)).to eq('bg-gray-800/30')
      end

      it 'returns gray background for 0%' do
        expect(helper.max_score_bg_color(0)).to eq('bg-gray-800/30')
      end
    end
  end

  describe '#max_score_text_color' do
    context 'when score is 90-100 (critical)' do
      it 'returns red text for 100%' do
        expect(helper.max_score_text_color(100)).to eq('text-red-600')
      end

      it 'returns red text for 90%' do
        expect(helper.max_score_text_color(90)).to eq('text-red-600')
      end
    end

    context 'when score is 75-89 (high)' do
      it 'returns amber text for 89%' do
        expect(helper.max_score_text_color(89)).to eq('text-amber-400')
      end

      it 'returns amber text for 75%' do
        expect(helper.max_score_text_color(75)).to eq('text-amber-400')
      end
    end

    context 'when score is 50-74 (medium)' do
      it 'returns blue text for 74%' do
        expect(helper.max_score_text_color(74)).to eq('text-blue-400')
      end

      it 'returns blue text for 50%' do
        expect(helper.max_score_text_color(50)).to eq('text-blue-400')
      end
    end

    context 'when score is 0-49 (low)' do
      it 'returns zinc text for 49%' do
        expect(helper.max_score_text_color(49)).to eq('text-zinc-300')
      end

      it 'returns zinc text for 0%' do
        expect(helper.max_score_text_color(0)).to eq('text-zinc-300')
      end
    end
  end

  describe '#variant_pill_classes' do
    let(:probe_result_passed) { instance_double('ProbeResult', any_detector_passed: true) }
    let(:probe_result_blocked) { instance_double('ProbeResult', any_detector_passed: false) }

    context 'when subindustry was not tested' do
      it 'returns grey background' do
        probe_results_map = { 1 => nil }

        expect(helper.variant_pill_classes(1, probe_results_map)).to eq('bg-zinc-800 text-zinc-500')
      end

      it 'returns grey background for missing subindustry' do
        probe_results_map = {}

        expect(helper.variant_pill_classes(999, probe_results_map)).to eq('bg-zinc-800 text-zinc-500')
      end
    end

    context 'when attack passed (successful attack)' do
      it 'returns red background' do
        probe_results_map = { 1 => probe_result_passed }

        expect(helper.variant_pill_classes(1, probe_results_map)).to eq('bg-red-950 text-red-400')
      end
    end

    context 'when attack failed (blocked)' do
      it 'returns purple background' do
        probe_results_map = { 1 => probe_result_blocked }

        expect(helper.variant_pill_classes(1, probe_results_map)).to eq('bg-purple-950 text-purple-400')
      end
    end
  end

  describe '#variant_category_text_classes' do
    let(:subindustry1) { instance_double('ThreatVariantSubindustry', id: 1) }
    let(:subindustry2) { instance_double('ThreatVariantSubindustry', id: 2) }
    let(:subindustries) { [ subindustry1, subindustry2 ] }

    context 'when any subindustry was tested' do
      it 'returns white text class' do
        probe_results_map = { 1 => instance_double('ProbeResult'), 2 => nil }

        expect(helper.variant_category_text_classes(subindustries, probe_results_map)).to eq('text-white')
      end

      it 'returns white text class when all tested' do
        probe_results_map = { 1 => instance_double('ProbeResult'), 2 => instance_double('ProbeResult') }

        expect(helper.variant_category_text_classes(subindustries, probe_results_map)).to eq('text-white')
      end
    end

    context 'when no subindustry was tested' do
      it 'returns grey text class' do
        probe_results_map = { 1 => nil, 2 => nil }

        expect(helper.variant_category_text_classes(subindustries, probe_results_map)).to eq('text-[#71717a]')
      end

      it 'returns grey text class for empty map' do
        probe_results_map = {}

        expect(helper.variant_category_text_classes(subindustries, probe_results_map)).to eq('text-[#71717a]')
      end
    end
  end

  describe '#formatted_duration' do
    context 'when report has start_time and end_time' do
      it 'returns human-readable duration for short scans' do
        report = create(:report,
                       start_time: Time.current,
                       end_time: Time.current + 30.seconds)

        result = helper.formatted_duration(report)

        expect(result).to match(/second|half a minute/)
      end

      it 'returns human-readable duration for minute-long scans' do
        report = create(:report,
                       start_time: Time.current,
                       end_time: Time.current + 5.minutes)

        result = helper.formatted_duration(report)

        expect(result).to include('minute')
      end

      it 'returns human-readable duration for hour-long scans' do
        report = create(:report,
                       start_time: Time.current,
                       end_time: Time.current + 2.hours)

        result = helper.formatted_duration(report)

        expect(result).to include('hour')
      end
    end

    context 'when report is missing start_time' do
      it 'returns N/A' do
        report = create(:report,
                       start_time: nil,
                       end_time: Time.current)

        expect(helper.formatted_duration(report)).to eq('N/A')
      end
    end

    context 'when report is missing end_time' do
      it 'returns N/A' do
        report = create(:report,
                       start_time: Time.current,
                       end_time: nil)

        expect(helper.formatted_duration(report)).to eq('N/A')
      end
    end

    context 'when report is missing both times' do
      it 'returns N/A' do
        report = create(:report,
                       start_time: nil,
                       end_time: nil)

        expect(helper.formatted_duration(report)).to eq('N/A')
      end
    end
  end
end
