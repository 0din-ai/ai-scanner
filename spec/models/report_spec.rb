require 'rails_helper'

RSpec.describe Report, type: :model do
  describe 'associations' do
    it 'belongs to scan' do
      association = Report.reflect_on_association(:scan)
      expect(association.macro).to eq :belongs_to
    end

    it 'belongs to target' do
      association = Report.reflect_on_association(:target)
      expect(association.macro).to eq :belongs_to
    end

    it { is_expected.to have_many(:probe_results).dependent(:destroy) }
    it { is_expected.to have_many(:detector_results).dependent(:destroy) }
    it { is_expected.to have_many(:detectors).through(:detector_results) }
    it { is_expected.to have_one(:report_debug_log).dependent(:destroy) }

    it "autosaves report_debug_log changes" do
      association = Report.reflect_on_association(:report_debug_log)

      expect(association.options[:autosave]).to be(true)
    end
  end

  describe 'validations' do
    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow_any_instance_of(ToastNotifier).to receive(:call)

      @target = create(:target)
      @scan = create(:complete_scan)
    end

    it 'validates presence of uuid' do
      report = build(:report, target: @target, scan: @scan)

      report.save

      report.uuid = nil
      expect(report.valid?).to be false
      expect(report.errors[:uuid]).to include("can't be blank")
    end

    it 'validates uniqueness of uuid' do
      uniqueness_validator = Report.validators_on(:uuid).find do |validator|
        validator.is_a?(ActiveRecord::Validations::UniquenessValidator)
      end

      expect(uniqueness_validator).to be_present
      expect(uniqueness_validator.attributes).to include(:uuid)
    end

    it 'validates presence of target' do
      report = build(:report, target: nil, skip_validate: true)
      expect(report).not_to be_valid
      expect(report.errors[:target]).to include("can't be blank")
    end

    it 'validates presence of scan' do
      report = build(:report, scan: nil, skip_validate: true)
      expect(report).not_to be_valid
      expect(report.errors[:scan]).to include("can't be blank")
    end
  end

  describe 'callbacks' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { build(:report, uuid: nil, name: nil, target: target, scan: scan) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow_any_instance_of(ToastNotifier).to receive(:call)
    end

    it 'generates a uuid before validation on create' do
      expect { report.valid? }.to change { report.uuid }.from(nil).to(String)
    end

    it 'generates a name before validation on create' do
      expect { report.valid? }.to change { report.name }.from(nil).to(String)
    end
  end

  describe 'notify_status_change callback' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    it 'sends success notification when status changes to completed' do
      expect(ToastNotifier).to receive(:call).with(
        type: "success",
        title: "Scan Completed",
        message: /has completed successfully/,
        link: Rails.application.routes.url_helpers.report_path(report),
        link_text: "View Report",
        company_id: report.company_id
      )
      report.update(status: :completed)
    end

    it 'sends error notification when status changes to failed' do
      expect(ToastNotifier).to receive(:call).with(
        type: "error",
        title: "Scan Failed",
        message: /has failed/,
        link: Rails.application.routes.url_helpers.report_path(report),
        link_text: "View Report",
        company_id: report.company_id
      )
      report.update(status: :failed)
    end

    it 'does not send notification for other status changes' do
      expect(ToastNotifier).not_to receive(:call)
      report.update(status: :processing)
    end
  end

  describe 'refund_scan_quota callback' do
    let(:company) { create(:company, :free, weekly_scan_count: 3, total_scans_count: 10, week_start_date: Date.current.beginning_of_week) }
    let(:target) { create(:target, company: company) }
    let(:scan) { create(:complete_scan, company: company) }
    let(:report) { create(:report, target: target, scan: scan, status: :running, company: company) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    it 'decrements scan count when report fails' do
      expect { report.update!(status: :failed) }.to change { company.reload.weekly_scan_count }.from(3).to(2)
    end

    it 'decrements scan count when report is stopped' do
      expect { report.update!(status: :stopped) }.to change { company.reload.weekly_scan_count }.from(3).to(2)
    end

    it 'does not decrement on completion' do
      expect { report.update!(status: :completed) }.not_to change { company.reload.weekly_scan_count }
    end

    it 'does not decrement on interrupted' do
      expect { report.update!(status: :interrupted) }.not_to change { company.reload.weekly_scan_count }
    end

    it 'decrements total_scans_count when report fails' do
      expect { report.update!(status: :failed) }.to change { company.reload.total_scans_count }.from(10).to(9)
    end
  end

  describe 'update_scan_cache callback' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan, status: :running) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)

      # Create some detector results for the report
      create(:detector_result, report: report, passed: 20, total: 50)
    end

    context 'when status changes to completed' do
      it 'updates the scan avg_successful_attacks cache' do
        expect(scan).to receive(:with_lock).and_yield
        expect(scan).to receive(:update_avg_successful_attacks!)

        report.update(status: :completed)
      end

      it 'uses database lock to prevent race conditions' do
        expect(scan).to receive(:with_lock).and_yield

        report.update(status: :completed)
      end
    end

    context 'when status changes to failed' do
      it 'updates the scan avg_successful_attacks cache' do
        expect(scan).to receive(:with_lock).and_yield
        expect(scan).to receive(:update_avg_successful_attacks!)

        report.update(status: :failed)
      end
    end

    context 'when status changes to other states' do
      it 'does not update cache when changing to processing' do
        expect(scan).not_to receive(:update_avg_successful_attacks!)

        report.update(status: :processing)
      end

      it 'does not update cache when changing to running' do
        report.update(status: :pending)
        expect(scan).not_to receive(:update_avg_successful_attacks!)

        report.update(status: :running)
      end
    end

    context 'when non-status attributes change' do
      it 'does not update cache when other attributes change' do
        report.update(status: :completed)
        scan.reload

        expect(scan).not_to receive(:update_avg_successful_attacks!)

        report.update(name: 'Updated Name')
      end
    end
  end

  describe 'status enum' do
    it { is_expected.to define_enum_for(:status).with_values(pending: 0, running: 1, processing: 2, completed: 3, failed: 4, stopped: 5, starting: 6, interrupted: 7) }
  end

  describe "#logs compatibility" do
    it "reads logs from report_debug_logs" do
      report = create(:report)
      create(:report_debug_log, report: report, logs: "stored logs")

      expect(report.reload.logs).to eq("stored logs")
    end

    it "persists logs assigned before saving" do
      report = build(:report)

      report.logs = "assigned logs"
      report.save!

      expect(report.reload.logs).to eq("assigned logs")
      expect(report.report_debug_log.logs).to eq("assigned logs")
    end

    it "persists logs assigned to an existing report" do
      report = create(:report)

      report.logs = "updated logs"
      report.save!

      expect(report.reload.logs).to eq("updated logs")
      expect(report.report_debug_log.logs).to eq("updated logs")
    end

    it "supports update! with logs" do
      report = create(:report)

      report.update!(logs: "updated through attributes")

      expect(report.reload.logs).to eq("updated through attributes")
      expect(report.report_debug_log.logs).to eq("updated through attributes")
    end

    it "preserves live tail metadata when assigning final logs" do
      report = create(:report)
      create(
        :report_debug_log,
        report: report,
        tail: "live tail\n",
        tail_offset: 12,
        tail_digest: "tail-digest",
        tail_truncated: true
      )

      report.logs = "final logs"
      report.save!

      debug_log = report.reload.report_debug_log
      expect(debug_log.logs).to eq("final logs")
      expect(debug_log.tail).to eq("live tail\n")
      expect(debug_log.tail_offset).to eq(12)
      expect(debug_log.tail_digest).to eq("tail-digest")
      expect(debug_log.tail_truncated).to be(true)
    end

    it "uses an existing row when the association cache was loaded empty" do
      report = create(:report)
      expect(report.report_debug_log).to be_nil

      now = Time.current
      ReportDebugLog.insert_all!(
        [
          {
            report_id: report.id,
            tail: "live tail\n",
            tail_offset: 10,
            tail_truncated: false,
            created_at: now,
            updated_at: now
          }
        ]
      )
      debug_log = ReportDebugLog.find_by!(report_id: report.id)

      report.logs = "final logs"
      report.save!

      expect(debug_log.reload.logs).to eq("final logs")
      expect(report.reload.report_debug_log.id).to eq(debug_log.id)
    end
  end

  describe 'status transitions' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, status: :pending, target: target, scan: scan) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    it 'can transition from pending to running' do
      expect { report.update(status: :running) }.to change { report.status }.from('pending').to('running')
    end

    it 'can transition from running to processing' do
      report.update(status: :running)
      expect { report.update(status: :processing) }
        .to change { report.status }.from('running').to('processing')
    end

    it 'can transition from processing to completed' do
      report.update(status: :processing)
      expect { report.update(status: :completed) }
        .to change { report.status }.from('processing').to('completed')
    end

    it 'can transition to failed from any state' do
      expect { report.update(status: :failed) }
        .to change { report.status }.from('pending').to('failed')
    end
  end

  describe '#detector_results_as_hash' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }
    let(:detector) { create(:detector, name: 'Test Detector') }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    it 'returns detector results as a hash' do
      detector_result = report.detector_results.create(
        detector: detector,
        passed: 8,
        total: 10,
      )

      result = report.detector_results_as_hash
      expect(result).to be_a(Hash)
      expect(result).to have_key('Test Detector')
      expect(result['Test Detector']).to include(
        'passed' => 8,
        'total' => 10,
      )
    end

    it 'handles missing detector gracefully' do
      detector_result = report.detector_results.create(
        detector: create(:detector, name: "Known Detector"),
        passed: 5,
        total: 10,
        max_score: 0
      )

      allow_any_instance_of(DetectorResult).to receive(:detector).and_return(nil)

      result = report.detector_results_as_hash
      expect(result).to have_key('Unknown')
      expect(result['Unknown']).to include(
        'passed' => 5,
        'total' => 10,
      )
    end

    it 'returns an empty hash when no detector results exist' do
      expect(report.detector_results_as_hash).to eq({})
    end
  end

  describe '#attack_success_rate' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    context 'with detector results' do
      it 'calculates correct ASR with single detector result' do
        create(:detector_result, report: report, passed: 8, total: 10)

        expect(report.attack_success_rate).to eq(80.0)
      end

      it 'calculates correct ASR with multiple detector results' do
        create(:detector_result, report: report, passed: 8, total: 10)
        create(:detector_result, report: report, passed: 6, total: 20)

        # Total: 14 passed out of 30 total = 46.67%
        expect(report.attack_success_rate).to eq(46.67)
      end

      it 'handles zero passed attacks' do
        create(:detector_result, report: report, passed: 0, total: 10)

        expect(report.attack_success_rate).to eq(0.0)
      end

      it 'handles 100% success rate' do
        create(:detector_result, report: report, passed: 10, total: 10)

        expect(report.attack_success_rate).to eq(100.0)
      end

      it 'rounds to 2 decimal places' do
        create(:detector_result, report: report, passed: 1, total: 3)

        # 1/3 = 0.33333... should round to 33.33
        expect(report.attack_success_rate).to eq(33.33)
      end
    end

    context 'with no detector results' do
      it 'returns 0 when no detector results exist' do
        expect(report.attack_success_rate).to eq(0)
      end
    end

    context 'with zero total attacks' do
      it 'returns 0 when total is zero' do
        create(:detector_result, report: report, passed: 0, total: 0)

        expect(report.attack_success_rate).to eq(0)
      end

      it 'returns 0 when multiple results have zero totals' do
        create(:detector_result, report: report, passed: 0, total: 0)
        create(:detector_result, report: report, passed: 0, total: 0)

        expect(report.attack_success_rate).to eq(0)
      end

      it 'handles mixed zero and non-zero totals correctly' do
        create(:detector_result, report: report, passed: 0, total: 0)
        create(:detector_result, report: report, passed: 5, total: 10)

        # Should only count the non-zero total: 5/10 = 50%
        expect(report.attack_success_rate).to eq(50.0)
      end
    end
  end

  describe '#formatted_asr' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    it 'returns formatted percentage for positive ASR' do
      create(:detector_result, report: report, passed: 8, total: 10)

      expect(report.formatted_asr).to eq('80.0%')
    end

    it 'returns N/A for zero ASR' do
      create(:detector_result, report: report, passed: 0, total: 10)

      expect(report.formatted_asr).to eq('N/A')
    end

    it 'returns N/A when no detector results exist' do
      expect(report.formatted_asr).to eq('N/A')
    end

    it 'returns N/A when all totals are zero' do
      create(:detector_result, report: report, passed: 0, total: 0)

      expect(report.formatted_asr).to eq('N/A')
    end

    it 'formats decimal values correctly' do
      create(:detector_result, report: report, passed: 1, total: 3)

      expect(report.formatted_asr).to eq('33.33%')
    end

    it 'handles 100% success rate' do
      create(:detector_result, report: report, passed: 15, total: 15)

      expect(report.formatted_asr).to eq('100.0%')
    end
  end

  describe 'ransackable attributes' do
    it 'includes asr in ransackable attributes' do
      expect(Report.ransackable_attributes).to include('asr')
    end

    it 'includes all expected attributes' do
      expected_attributes = [ "company_id", "name", "created_at", "id", "status", "target_id", "updated_at", "uuid", "asr" ]
      expect(Report.ransackable_attributes).to match_array(expected_attributes)
    end
  end

  describe 'OSS variant stubs' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    it '#is_variant_report? returns false' do
      expect(report.is_variant_report?).to be false
    end

    it '#has_variant_data? returns false' do
      expect(report.has_variant_data?).to be false
    end

    it '#should_show_variants_section? returns false' do
      expect(report.should_show_variants_section?).to be false
    end

    it '#variant_report_ready? returns false' do
      expect(report.variant_report_ready?).to be false
    end

    it '#variant_count returns 0' do
      expect(report.variant_count).to eq(0)
    end

    it '#preloaded_variant_summary_data returns empty summary structure' do
      expect(report.preloaded_variant_summary_data).to eq({
        attack_counts: {}, success_rates: {}, subindustry_maps: {}
      })
    end
  end

  describe '#all_attempts_for_probe' do
    let(:report) { create(:report) }
    let(:probe) { create(:probe) }
    let(:detector) { create(:detector) }

    it 'returns empty array when probe_result is nil' do
      expect(report.all_attempts_for_probe(nil)).to eq([])
    end

    it 'returns main attempts only (no variant data in OSS)' do
      probe_result = create(:probe_result, report: report, probe: probe, detector: detector,
                            attempts: [
                              { 'prompt' => 'Test prompt', 'outputs' => [ 'Test response' ] }
                            ])

      result = report.all_attempts_for_probe(probe_result)

      expect(result.size).to eq(1)
      expect(result[0][:is_variant]).to be false
      expect(result[0][:variant_industry]).to be_nil
      expect(result[0][:attempt]['prompt']).to eq('Test prompt')
    end

    it 'handles nil attempts on probe_result' do
      probe_result = create(:probe_result, report: report, probe: probe, detector: detector,
                            attempts: nil)

      result = report.all_attempts_for_probe(probe_result)
      expect(result).to eq([])
    end

    it 'loads only the requested probe attempts for variant data' do
      other_probe = create(:probe)
      child_report = create(:report, parent_report: report, scan: report.scan, target: report.target, company: report.company)
      subindustry = create(:threat_variant_subindustry)
      threat_variant = create(:threat_variant, probe: probe, threat_variant_subindustry: subindustry)
      other_threat_variant = create(:threat_variant, probe: other_probe, threat_variant_subindustry: subindustry)
      probe_result = create(:probe_result, report: report, probe: probe, detector: detector,
                            attempts: [ { 'prompt' => 'parent prompt' } ])
      create(:probe_result, report: child_report, probe: probe, detector: detector,
                            threat_variant: threat_variant,
                            attempts: [ { 'prompt' => 'variant prompt' } ])
      create(:probe_result, report: child_report, probe: other_probe, detector: detector,
                            threat_variant: other_threat_variant,
                            attempts: [ { 'prompt' => 'other variant prompt' } ])

      expect(report).not_to receive(:preloaded_variant_summary_data)

      result = report.all_attempts_for_probe(probe_result)

      expect(result.map { |item| item[:attempt]['prompt'] }).to eq([ 'parent prompt', 'variant prompt' ])
      expect(result.map { |item| item[:is_variant] }).to eq([ false, true ])
      expect(result.last[:variant_industry]).to include(subindustry.name)
    end
  end

  describe 'token methods (computed from probe_results)' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }
    let(:probe1) { create(:probe) }
    let(:probe2) { create(:probe) }
    let(:detector) { create(:detector) }

    describe '#input_tokens' do
      it 'returns 0 when no probe_results exist' do
        expect(report.input_tokens).to eq(0)
      end

      it 'sums input_tokens from all probe_results' do
        create(:probe_result, report: report, probe: probe1, detector: detector, input_tokens: 100, output_tokens: 50)
        create(:probe_result, report: report, probe: probe2, detector: detector, input_tokens: 200, output_tokens: 75)
        expect(report.input_tokens).to eq(300)
      end
    end

    describe '#output_tokens' do
      it 'returns 0 when no probe_results exist' do
        expect(report.output_tokens).to eq(0)
      end

      it 'sums output_tokens from all probe_results' do
        create(:probe_result, report: report, probe: probe1, detector: detector, input_tokens: 100, output_tokens: 50)
        create(:probe_result, report: report, probe: probe2, detector: detector, input_tokens: 200, output_tokens: 75)
        expect(report.output_tokens).to eq(125)
      end
    end

    describe '#total_tokens' do
      it 'returns sum of input and output tokens from probe_results' do
        create(:probe_result, report: report, probe: probe1, detector: detector, input_tokens: 1000, output_tokens: 500)
        expect(report.total_tokens).to eq(1500)
      end

      it 'returns 0 when no probe_results exist' do
        expect(report.total_tokens).to eq(0)
      end
    end
  end

  describe 'broadcast_running_stats_if_needed callback' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan, status: :pending) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    describe 'transitions TO active states' do
      it 'triggers broadcast with company_id when changing to running' do
        expect(BroadcastRunningStatsJob).to receive(:perform_later).with(report.company_id)
        report.update!(status: :running)
      end

      it 'triggers broadcast with company_id when changing to starting' do
        expect(BroadcastRunningStatsJob).to receive(:perform_later).with(report.company_id)
        report.update!(status: :starting)
      end
    end

    describe 'transitions FROM active states' do
      before do
        # First set to running without triggering expectations
        allow(BroadcastRunningStatsJob).to receive(:perform_later)
        report.update!(status: :running)
      end

      it 'triggers broadcast with company_id when changing from running to completed' do
        expect(BroadcastRunningStatsJob).to receive(:perform_later).with(report.company_id)
        report.update!(status: :completed)
      end

      it 'triggers broadcast with company_id when changing from running to failed' do
        expect(BroadcastRunningStatsJob).to receive(:perform_later).with(report.company_id)
        report.update!(status: :failed)
      end

      it 'triggers broadcast with company_id when changing from running to stopped' do
        expect(BroadcastRunningStatsJob).to receive(:perform_later).with(report.company_id)
        report.update!(status: :stopped)
      end
    end

    describe 'transitions between non-active states' do
      it 'does not trigger broadcast when changing from pending to failed' do
        expect(BroadcastRunningStatsJob).not_to receive(:perform_later)
        report.update!(status: :failed)
      end

      it 'does not trigger broadcast when changing from pending to processing' do
        expect(BroadcastRunningStatsJob).not_to receive(:perform_later)
        report.update!(status: :processing)
      end

      it 'does not trigger broadcast when changing from completed to failed' do
        allow(BroadcastRunningStatsJob).to receive(:perform_later)
        report.update!(status: :running)
        report.update!(status: :completed)

        expect(BroadcastRunningStatsJob).not_to receive(:perform_later)
        report.update!(status: :failed)
      end
    end

    describe 'transitions between active states' do
      before do
        allow(BroadcastRunningStatsJob).to receive(:perform_later)
        report.update!(status: :starting)
      end

      it 'triggers broadcast with company_id when changing from starting to running' do
        # Both are active, but the count might not change - still broadcasts for consistency
        expect(BroadcastRunningStatsJob).to receive(:perform_later).with(report.company_id)
        report.update!(status: :running)
      end
    end

    describe 'uses after_commit' do
      it 'triggers job with company_id after transaction commits' do
        # The callback is after_commit, so job should be queued after commit
        expect(BroadcastRunningStatsJob).to receive(:perform_later).with(report.company_id)

        Report.transaction do
          report.update!(status: :running)
          # Job should not be called yet inside transaction
        end
        # Job should be called after transaction commits
      end
    end
  end

  describe 'metrics collection' do
    let(:report) { create(:report, status: :pending) }

    before do
      allow(MonitoringService).to receive(:active?).and_return(true)
      allow(MonitoringService).to receive(:current_trace_id).and_return('test-trace-123')
      allow(MonitoringService).to receive(:set_labels)
      allow(MonitoringService).to receive(:transaction).and_yield
    end

    describe '#collect_metrics' do
      context 'when monitoring is active' do
        it 'collects metrics on status change to starting' do
          expect(report).to receive(:record_queue_wait_metric)

          report.update!(status: :starting)
        end

        it 'collects metrics on status change to completed' do
          expect(report).to receive(:record_all_completion_metrics)

          report.update!(status: :completed)
        end

        it 'collects metrics on status change to failed' do
          expect(report).to receive(:record_all_completion_metrics)

          report.update!(status: :failed)
        end

        it 'does not collect metrics when status does not change' do
          report.update!(status: :running)

          expect(MonitoringService).not_to receive(:set_labels)

          report.save!
        end
      end

      context 'when monitoring is not active' do
        before do
          allow(MonitoringService).to receive(:active?).and_return(false)
        end

        it 'does not collect metrics' do
          expect(MonitoringService).not_to receive(:set_labels)

          report.update!(status: :completed)
        end
      end
    end

    describe '#record_queue_wait_metric' do
      it 'records queue wait time in seconds' do
        report.created_at = 10.seconds.ago
        report.updated_at = Time.current
        report.save!

        report.update!(status: :starting)

        expect(MonitoringService).to have_received(:set_labels).with(
          hash_including(queue_wait_seconds: be_within(2).of(10))
        )
      end

      it 'includes base metric labels' do
        report.update!(status: :starting)

        expect(MonitoringService).to have_received(:set_labels).with(
          hash_including(
            target_name: report.target.name,
            target_model: report.target.model,
            scan_name: report.scan.name,
            scan_id: report.scan.id,
            report_uuid: report.uuid
          )
        )
      end
    end

    describe '#record_all_completion_metrics' do
      before do
        report.created_at = 30.seconds.ago
        report.updated_at = Time.current
        report.save!
      end

      context 'when status is completed' do
        before do
          # Create probe_results with token counts
          create(:probe_result, report: report, input_tokens: 600, output_tokens: 300)
          create(:probe_result, report: report, input_tokens: 400, output_tokens: 200)
        end

        it 'records scan success as 1' do
          report.update!(status: :completed)

          expect(MonitoringService).to have_received(:set_labels).with(
            hash_including(
              scan_success: 1,
              scan_status: 'completed'
            )
          )
        end

        it 'records token metrics' do
          report.update!(status: :completed)

          expect(MonitoringService).to have_received(:set_labels).with(
            hash_including(
              input_tokens: 1000,
              output_tokens: 500,
              total_tokens: 1500
            )
          )
        end

        it 'records scan duration' do
          report.update!(status: :completed)

          expect(MonitoringService).to have_received(:set_labels).with(
            hash_including(scan_duration_seconds: be_within(2).of(30))
          )
        end

        it 'records token deviation when projected tokens exist' do
          # Create probes with input_tokens and add them to the scan
          probe1 = create(:probe, input_tokens: 500)
          probe2 = create(:probe, input_tokens: 300)
          report.scan.probes << [ probe1, probe2 ]

          report.update!(status: :completed)

          expect(MonitoringService).to have_received(:set_labels).with(
            hash_including(
              token_deviation_percent: 25.0,
              projected_input_tokens: 800
            )
          )
        end
      end

      context 'when status is failed' do
        it 'records scan success as 0' do
          report.update!(status: :failed)

          expect(MonitoringService).to have_received(:set_labels).with(
            hash_including(
              scan_success: 0,
              scan_status: 'failed'
            )
          )
        end

        it 'does not include token metrics' do
          report.update!(status: :failed)

          expect(MonitoringService).to have_received(:set_labels).with(
            hash_not_including(:input_tokens, :output_tokens, :total_tokens)
          )
        end
      end

      context 'when status is stopped' do
        it 'records scan success as 0' do
          report.update!(status: :stopped)

          expect(MonitoringService).to have_received(:set_labels).with(
            hash_including(
              scan_success: 0,
              scan_status: 'stopped'
            )
          )
        end
      end
    end

    describe '#build_base_metric_labels' do
      it 'returns hash with target, scan, and report identifiers' do
        labels = report.send(:build_base_metric_labels)

        expect(labels).to include(
          target_name: report.target.name,
          target_model: report.target.model,
          scan_name: report.scan.name,
          scan_id: report.scan.id,
          report_uuid: report.uuid
        )
      end

      it 'includes monitoring trace id when monitoring is active' do
        labels = report.send(:build_base_metric_labels)

        expect(labels).to include(trace_id: 'test-trace-123')
      end

      it 'includes "none" as trace id when monitoring is inactive' do
        allow(MonitoringService).to receive(:active?).and_return(false)

        labels = report.send(:build_base_metric_labels)

        expect(labels).to include(trace_id: 'none')
      end
    end
  end

  describe "removed methods" do
    it "no longer exposes #preloaded_variant_data" do
      expect(Report.new).not_to respond_to(:preloaded_variant_data)
    end
  end
end
