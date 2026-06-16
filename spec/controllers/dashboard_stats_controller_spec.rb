require 'rails_helper'

RSpec.describe DashboardStatsController, type: :controller do
  let(:user) { create(:user) }

  before { sign_in user }

  describe '#total_scans_data' do
    let(:mock_result) { { data: [ 1, 2, 3 ] } }
    let(:mock_service) { instance_double(Stats::TotalScansData, call: mock_result) }

    before do
      allow(Stats::TotalScansData).to receive(:new).and_return(mock_service)
    end

    context 'when days parameter is provided' do
      it 'calls the service with the provided days' do
        get :total_scans_data, params: { days: '7' }

        expect(Stats::TotalScansData).to have_received(:new).with(days: 7)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is not provided' do
      it 'calls the service with default days value of 1' do
        get :total_scans_data

        expect(Stats::TotalScansData).to have_received(:new).with(days: 1)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is invalid' do
      it 'calls the service with default days value of 1' do
        get :total_scans_data, params: { days: '0' }

        expect(Stats::TotalScansData).to have_received(:new).with(days: 1)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end
  end

  describe '#avg_asr_score' do
    let(:mock_result) { { score: 85 } }

    before do
      allow(Stats::AverageAsrScore).to receive(:call).and_return(mock_result)
    end

    context 'when days parameter is provided' do
      it 'calls the service with the provided days' do
        get :avg_asr_score, params: { days: '14' }

        expect(Stats::AverageAsrScore).to have_received(:call).with(days: 14)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is not provided' do
      it 'calls the service with default days value of 7' do
        get :avg_asr_score

        expect(Stats::AverageAsrScore).to have_received(:call).with(days: 7)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is invalid' do
      it 'calls the service with default days value of 7' do
        get :avg_asr_score, params: { days: '0' }

        expect(Stats::AverageAsrScore).to have_received(:call).with(days: 7)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end
  end

  describe '#avg_scan_time_data' do
    let(:mock_result) { { avg_time: 120 } }
    let(:mock_service) { instance_double(Stats::AvgScanTimeData, call: mock_result) }

    before do
      allow(Stats::AvgScanTimeData).to receive(:new).and_return(mock_service)
    end

    context 'when days parameter is provided' do
      it 'calls the service with the provided days' do
        get :avg_scan_time_data, params: { days: '10' }

        expect(Stats::AvgScanTimeData).to have_received(:new).with(days: 10)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is not provided' do
      it 'calls the service with default days value of 7' do
        get :avg_scan_time_data

        expect(Stats::AvgScanTimeData).to have_received(:new).with(days: 7)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is invalid' do
      it 'calls the service with default days value of 7' do
        get :avg_scan_time_data, params: { days: '0' }

        expect(Stats::AvgScanTimeData).to have_received(:new).with(days: 7)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end
  end

  describe '#probes_data' do
    let(:mock_result) { { probes: [ { id: 1, name: 'Probe 1' } ] } }
    let(:mock_service) { instance_double(Stats::ProbesData, call: mock_result) }

    before do
      allow(Stats::ProbesData).to receive(:new).and_return(mock_service)
    end

    context 'when days parameter is provided' do
      it 'calls the service with the provided days' do
        get :probes_data, params: { days: '60' }

        expect(Stats::ProbesData).to have_received(:new).with(days: 60)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is not provided' do
      it 'calls the service with default days value of 30' do
        get :probes_data

        expect(Stats::ProbesData).to have_received(:new).with(days: 30)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is invalid' do
      it 'calls the service with default days value of 30' do
        get :probes_data, params: { days: '0' }

        expect(Stats::ProbesData).to have_received(:new).with(days: 30)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end
  end

  describe '#targets_timeline_data' do
    let(:mock_result) { { targets: [ { id: 1, name: 'Target 1' } ] } }
    let(:mock_service) { instance_double(Stats::TargetsTimelineData, call: mock_result) }

    before do
      allow(Stats::TargetsTimelineData).to receive(:new).and_return(mock_service)
    end

    it 'calls the service and returns the result as JSON' do
      get :targets_timeline_data

      expect(Stats::TargetsTimelineData).to have_received(:new)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end

  describe '#vulnerable_targets_over_time' do
    let(:mock_result) { { data: [ { date: '2023-01-01', count: 5 } ] } }
    let(:mock_service) { instance_double(Stats::VulnerableTargetsOverTime, call: mock_result) }

    before do
      allow(Stats::VulnerableTargetsOverTime).to receive(:new).and_return(mock_service)
    end

    context 'when days parameter is provided' do
      it 'calls the service with the provided days' do
        get :vulnerable_targets_over_time, params: { days: '60' }

        expect(Stats::VulnerableTargetsOverTime).to have_received(:new).with(days: 60)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is not provided' do
      it 'calls the service with default days value of 30' do
        get :vulnerable_targets_over_time

        expect(Stats::VulnerableTargetsOverTime).to have_received(:new).with(days: 30)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end

    context 'when days parameter is invalid' do
      it 'calls the service with default days value of 30' do
        get :vulnerable_targets_over_time, params: { days: '0' }

        expect(Stats::VulnerableTargetsOverTime).to have_received(:new).with(days: 30)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(mock_result.as_json)
      end
    end
  end

  describe '#reports_timeline_data' do
    let(:mock_result) { { reports: [ { id: 1, date: '2023-01-01' } ] } }
    let(:mock_service) { instance_double(Stats::ReportsTimelineData, call: mock_result) }

    before do
      allow(Stats::ReportsTimelineData).to receive(:new).and_return(mock_service)
    end

    it 'calls the service with the provided parameters' do
      get :reports_timeline_data, params: { target_id: '1', scan_id: '2' }

      expect(Stats::ReportsTimelineData).to have_received(:new).with(target_id: '1', scan_id: '2')
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end

  describe '#probes_passed_failed_timeline_data' do
    let(:mock_result) { { dates: [ '01 Jan', '02 Jan' ], asr_percentages: [ 75.5, 82.3 ] } }
    let(:mock_service) { instance_double(Stats::ProbesPassedFailedTimelineData, call: mock_result) }

    before do
      allow(Stats::ProbesPassedFailedTimelineData).to receive(:new).and_return(mock_service)
    end

    it 'calls the service with the provided target_id' do
      get :probes_passed_failed_timeline_data, params: { target_id: '1' }

      expect(Stats::ProbesPassedFailedTimelineData).to have_received(:new).with(target_id: '1')
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end

  describe '#probe_results_timeline_data' do
    let(:mock_result) { { results: [ { date: '2023-01-01', status: 'passed' } ] } }
    let(:mock_service) { instance_double(Stats::ProbeResultsTimelineData, call: mock_result) }

    before do
      allow(Stats::ProbeResultsTimelineData).to receive(:new).and_return(mock_service)
    end

    it 'calls the service with the provided probe_id' do
      get :probe_results_timeline_data, params: { probe_id: '1' }

      expect(Stats::ProbeResultsTimelineData).to have_received(:new).with(probe_id: '1')
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end

  describe '#probe_success_rate_data' do
    let(:mock_result) { { success_rate: 75 } }
    let(:mock_service) { instance_double(Stats::ProbeSuccessRateData, call: mock_result) }

    before do
      allow(Stats::ProbeSuccessRateData).to receive(:new).and_return(mock_service)
    end

    it 'calls the service with the provided parameters' do
      get :probe_success_rate_data, params: { probe_id: '1', target_id: '2', scan_id: '3', report_id: '4' }

      expect(Stats::ProbeSuccessRateData).to have_received(:new).with(
        probe_id: '1', target_id: '2', scan_id: '3', report_id: '4'
      )
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end

  describe '#detector_activity_data' do
    let(:mock_result) { { activity: [ { date: '2023-01-01', count: 5 } ] } }
    let(:mock_service) { instance_double(Stats::DetectorActivityData, call: mock_result) }

    before do
      allow(Stats::DetectorActivityData).to receive(:new).and_return(mock_service)
    end

    it 'calls the service with the provided parameters' do
      get :detector_activity_data, params: { target_id: '1', scan_id: '2', report_id: '3' }

      expect(Stats::DetectorActivityData).to have_received(:new).with(
        target_id: '1', scan_id: '2', report_id: '3'
      )
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end

  describe '#attack_fails_by_target_data' do
    let(:mock_result) { { targets: [ { id: 1, name: 'Target 1', fails: 5 } ] } }
    let(:mock_service) { instance_double(Stats::AttackFailsByTargetData, call: mock_result) }

    before do
      allow(Stats::AttackFailsByTargetData).to receive(:new).and_return(mock_service)
    end

    it 'calls the service with the provided scan_id' do
      get :attack_fails_by_target_data, params: { scan_id: '1' }

      expect(Stats::AttackFailsByTargetData).to have_received(:new).with(scan_id: '1')
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end

  describe '#taxonomy_distribution_data' do
    let(:mock_result) { { categories: [ 'Category 1' ], data: [ { name: 'Category 1', value: 10 } ] } }
    let(:mock_service) { instance_double(Stats::TaxonomyDistributionData, call: mock_result) }

    before do
      allow(Stats::TaxonomyDistributionData).to receive(:new).and_return(mock_service)
    end

    it 'calls the service and returns the result as JSON' do
      get :taxonomy_distribution_data

      expect(Stats::TaxonomyDistributionData).to have_received(:new)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end

  describe '#probe_disclosure_stats' do
    let(:mock_result) { { labels: [ '0-day', 'n-day' ], values: [ 5, 10 ] } }
    let(:mock_service) { instance_double(Stats::ProbeDisclosureStats, call: mock_result) }

    before do
      allow(Stats::ProbeDisclosureStats).to receive(:new).and_return(mock_service)
    end

    it 'calls the service and returns the result as JSON' do
      get :probe_disclosure_stats

      expect(Stats::ProbeDisclosureStats).to have_received(:new)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(mock_result.as_json)
    end
  end
end
