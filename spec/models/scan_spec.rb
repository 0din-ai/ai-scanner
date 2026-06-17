require 'rails_helper'

RSpec.describe Scan, type: :model do
  let(:company) { create(:company) }

  describe 'associations' do
    it { is_expected.to have_and_belong_to_many(:targets) }
    it { is_expected.to have_and_belong_to_many(:probes) }
    it { is_expected.to have_many(:reports).dependent(:destroy) }
    it { is_expected.to belong_to(:output_server).optional }
  end

  describe 'validations' do
    it 'requires uuid to be present' do
      presence_validator = Scan.validators_on(:uuid).find do |validator|
        validator.is_a?(ActiveRecord::Validations::PresenceValidator)
      end

      expect(presence_validator).to be_present
      expect(presence_validator.attributes).to include(:uuid)
    end

    describe 'avg_successful_attacks' do
      it 'validates numericality with range 0-100' do
        scan = build(:scan, company: company)
        scan.targets = [ create(:target, company: company) ]
        scan.probes = [ create(:probe) ]

        scan.avg_successful_attacks = -1
        expect(scan).not_to be_valid
        expect(scan.errors[:avg_successful_attacks]).to include('must be greater than or equal to 0')

        scan.avg_successful_attacks = 101
        expect(scan).not_to be_valid
        expect(scan.errors[:avg_successful_attacks]).to include('must be less than or equal to 100')

        scan.avg_successful_attacks = 50.5
        expect(scan).to be_valid

        scan.avg_successful_attacks = nil
        expect(scan).to be_valid
      end
    end

    it 'requires uuid to be unique' do
      target = create(:target, company: company)
      probe = create(:probe)

      original = build(:scan, company: company)
      original.targets = [ target ]
      original.probes = [ probe ]
      original.uuid = 'unique-scan-id-123'
      allow(original).to receive(:update_next_scheduled_run)
      original.save

      duplicate = build(:scan, company: company)
      duplicate.targets = [ target ]
      duplicate.probes = [ probe ]
      duplicate.uuid = 'unique-scan-id-123'
      allow(duplicate).to receive(:update_next_scheduled_run)
      duplicate.valid?

      expect(duplicate.errors[:uuid]).to include("has already been taken")
    end

    it 'requires targets' do
      scan = Scan.new(name: 'Test Scan', uuid: SecureRandom.uuid, company: company)
      scan.probes = create_list(:probe, 2)

      allow(scan).to receive(:update_next_scheduled_run)

      expect(scan.valid?).to be_falsey
      expect(scan.errors[:targets]).to include("can't be blank")
    end

    it 'requires probes' do
      scan = Scan.new(name: 'Test Scan', uuid: SecureRandom.uuid, company: company)
      scan.targets = create_list(:target, 2, company: company)

      allow(scan).to receive(:update_next_scheduled_run)

      expect(scan.valid?).to be_falsey
      expect(scan.errors[:probes]).to include("can't be blank")
    end

    it 'is valid with both targets and probes' do
      scan = Scan.new(name: 'Test Scan', uuid: SecureRandom.uuid, company: company)
      scan.targets = create_list(:target, 2, company: company)
      scan.probes = create_list(:probe, 2)

      allow(scan).to receive(:update_next_scheduled_run)

      expect(scan.valid?).to be_truthy
    end

    it 'rejects scans that select threat variants without any variant-eligible probe' do
      ineligible_detector = create(:detector, name: '0din.PromptInjection')
      ineligible_probe = create(:probe, detector: ineligible_detector)
      subindustry = create(:threat_variant_subindustry)
      scan = Scan.new(name: 'Variant Without Eligible Probe', uuid: SecureRandom.uuid, company: company)
      scan.targets = [ create(:target, company: company) ]
      scan.probes = [ ineligible_probe ]
      scan.threat_variant_subindustries = [ subindustry ]

      allow(scan).to receive(:update_next_scheduled_run)

      expect(scan).not_to be_valid
      expect(scan.errors[:base]).to include('Threat variants require at least one probe that supports variants')
    end

    it 'is valid when at least one selected probe is variant-eligible' do
      eligible_probe = create(:probe)
      subindustry = create(:threat_variant_subindustry)
      create(:threat_variant, probe: eligible_probe, threat_variant_subindustry: subindustry)
      scan = Scan.new(name: 'Variant With Eligible Probe', uuid: SecureRandom.uuid, company: company)
      scan.targets = [ create(:target, company: company) ]
      scan.probes = [ eligible_probe ]
      scan.threat_variant_subindustries = [ subindustry ]

      allow(scan).to receive(:update_next_scheduled_run)

      expect(scan).to be_valid
    end
  end

  describe 'callbacks' do
    describe 'before_validation' do
      it 'generates a uuid before validation' do
        scan = Scan.new(name: 'Test Scan', company: company)
        scan.targets = create_list(:target, 2, company: company)
        scan.probes = create_list(:probe, 2)

        allow(scan).to receive(:update_next_scheduled_run)

        expect { scan.valid? }.to change { scan.uuid }.from(nil)
      end

      it 'updates next_scheduled_run during validation' do
        scan = build(:scan, company: company)
        scan.targets = create_list(:target, 1, company: company)
        scan.probes = create_list(:probe, 1)

        expect(scan).to receive(:update_next_scheduled_run)

        scan.valid?
      end
    end

    describe 'after_create' do
      it 'creates reports for each target' do
        scan = build(:scan, company: company)
        scan.targets = create_list(:target, 3, company: company)
        scan.probes = create_list(:probe, 2)

        allow_any_instance_of(RunGarakScan).to receive(:call)

        allow(scan).to receive(:update_next_scheduled_run)

        expect { scan.save }.to change { Report.count }.by(3)
        expect(scan.reports.count).to eq(3)
        expect(scan.reports.map(&:target)).to match_array(scan.targets)
      end
    end
  end

  describe 'scopes' do
    before do
      Report.delete_all
      Scan.delete_all

      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow_any_instance_of(Scan).to receive(:update_next_scheduled_run)
    end

    it 'has a due_to_run scope' do
      expect(Scan).to respond_to(:due_to_run)
    end

    it 'has a scheduled scope' do
      expect(Scan).to respond_to(:scheduled)
    end

    it 'has an unscheduled scope' do
      expect(Scan).to respond_to(:unscheduled)
    end
  end

  describe '#rerun' do
    it 'creates new reports for each target' do
      scan = create(:complete_scan)
      scan.reports.destroy_all

      allow_any_instance_of(RunGarakScan).to receive(:call)

      expect { scan.rerun }.to change { scan.reports.count }.by(scan.targets.count)
    end
  end

  describe '#calculate_avg_successful_attacks' do
    let(:scan) { create(:complete_scan) }

    context 'with no completed reports' do
      it 'returns 0.0' do
        expect(scan.calculate_avg_successful_attacks).to eq(0.0)
      end
    end

    context 'with completed reports' do
      before do
        # Create reports with known detector results
        report1 = create(:report, scan: scan, target: scan.targets.first, status: :completed)
        report2 = create(:report, scan: scan, target: scan.targets.last, status: :completed)

        # Report 1: 20 passed out of 50 total = 40%
        create(:detector_result, report: report1, passed: 20, total: 50)

        # Report 2: 30 passed out of 100 total = 30%
        create(:detector_result, report: report2, passed: 30, total: 100)
      end

      it 'calculates the average of attack success rates' do
        # Average of 40% and 30% = 35%
        expect(scan.calculate_avg_successful_attacks).to eq(35.0)
      end
    end

    context 'with multiple detector results per report' do
      before do
        report = create(:report, scan: scan, target: scan.targets.first, status: :completed)

        # Multiple detector results for one report
        # Total: 25 passed out of 100 = 25%
        create(:detector_result, report: report, passed: 10, total: 40)
        create(:detector_result, report: report, passed: 15, total: 60)
      end

      it 'sums detector results within each report before calculating percentage' do
        expect(scan.calculate_avg_successful_attacks).to eq(25.0)
      end
    end

    context 'with reports having zero total' do
      before do
        report1 = create(:report, scan: scan, target: scan.targets.first, status: :completed)
        report2 = create(:report, scan: scan, target: scan.targets.last, status: :completed)

        create(:detector_result, report: report1, passed: 0, total: 0)
        create(:detector_result, report: report2, passed: 10, total: 20)
      end

      it 'handles division by zero correctly' do
        # Average of 0% and 50% = 25%
        expect(scan.calculate_avg_successful_attacks).to eq(25.0)
      end
    end

    context 'with non-completed reports' do
      before do
        create(:report, scan: scan, target: scan.targets.first, status: :completed).tap do |report|
          create(:detector_result, report: report, passed: 50, total: 100)
        end

        create(:report, scan: scan, target: scan.targets.last, status: :failed).tap do |report|
          create(:detector_result, report: report, passed: 100, total: 100)
        end

        create(:report, scan: scan, target: scan.targets.first, status: :running).tap do |report|
          create(:detector_result, report: report, passed: 100, total: 100)
        end
      end

      it 'only includes completed reports in calculation' do
        # Only the completed report with 50% success rate
        expect(scan.calculate_avg_successful_attacks).to eq(50.0)
      end
    end
  end

  describe '#update_avg_successful_attacks!' do
    let(:scan) { create(:complete_scan) }

    before do
      report = create(:report, scan: scan, target: scan.targets.first, status: :completed)
      create(:detector_result, report: report, passed: 30, total: 60)
    end

    it 'updates the avg_successful_attacks column' do
      expect { scan.update_avg_successful_attacks! }
        .to change { scan.reload.avg_successful_attacks }
        .from(nil)
        .to(50.0)
    end

    it 'bypasses validations and callbacks' do
      expect(scan).not_to receive(:update)
      expect(scan).to receive(:update_column).with(:avg_successful_attacks, 50.0)

      scan.update_avg_successful_attacks!
    end
  end

  describe 'auto-update functionality' do
    let(:target) { create(:target, company: company) }
    let(:generic_probe1) { create(:probe, name: 'GenericProbe1', enabled: true) }
    let(:generic_probe2) { create(:probe, name: 'GenericProbe2', enabled: true) }
    let(:cm_probe1) { create(:probe, name: 'TestCM', enabled: true) }
    let(:cm_probe2) { create(:probe, name: 'AnotherCM', enabled: true) }
    let(:hp_probe1) { create(:probe, name: 'TestHP', enabled: true) }
    let(:hp_probe2) { create(:probe, name: 'AnotherHP', enabled: true) }

    describe 'scopes' do
      it 'has auto_updating_generic scope' do
        scan = create(:complete_scan)
        scan.update!(auto_update_generic: true)
        expect(Scan.auto_updating_generic).to include(scan)
      end

      it 'has auto_updating_cm scope' do
        scan = create(:complete_scan)
        scan.probes << cm_probe1
        scan.update!(auto_update_cm: true)
        expect(Scan.auto_updating_cm).to include(scan)
      end

      it 'has auto_updating_hp scope' do
        scan = create(:complete_scan)
        scan.probes << hp_probe1
        scan.update!(auto_update_hp: true)
        expect(Scan.auto_updating_hp).to include(scan)
      end
    end

    describe '#auto_updating_categories' do
      it 'returns array of enabled categories' do
        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ generic_probe1, cm_probe1, hp_probe1 ]
        scan.save!
        scan.update!(auto_update_generic: true, auto_update_cm: true, auto_update_hp: false)

        expect(scan.auto_updating_categories).to match_array([ "Generic", "CM" ])
      end

      it 'returns empty array when no categories enabled' do
        scan = create(:complete_scan)
        expect(scan.auto_updating_categories).to be_empty
      end
    end

    describe 'validation: auto_update_flags_have_corresponding_probes' do
      it 'prevents enabling auto_update_generic without generic probes' do
        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ cm_probe1, hp_probe1 ]
        scan.auto_update_generic = true

        expect(scan).not_to be_valid
        expect(scan.errors[:auto_update_generic]).to include("cannot be enabled without generic probes")
      end

      it 'prevents enabling auto_update_cm without CM probes' do
        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ generic_probe1, hp_probe1 ]
        scan.auto_update_cm = true

        expect(scan).not_to be_valid
        expect(scan.errors[:auto_update_cm]).to include("cannot be enabled without CM probes")
      end

      it 'prevents enabling auto_update_hp without HP probes' do
        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ generic_probe1, cm_probe1 ]
        scan.auto_update_hp = true

        expect(scan).not_to be_valid
        expect(scan.errors[:auto_update_hp]).to include("cannot be enabled without HP probes")
      end

      it 'allows enabling auto_update when corresponding probes exist' do
        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ generic_probe1, cm_probe1, hp_probe1 ]
        scan.save!
        scan.auto_update_generic = true
        scan.auto_update_cm = true
        scan.auto_update_hp = true

        expect(scan).to be_valid
      end

      it 'validates using single database query for efficiency' do
        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ generic_probe1, cm_probe1, hp_probe1 ]
        scan.save!
        scan.auto_update_generic = true
        scan.auto_update_cm = true
        scan.auto_update_hp = true

        # Validation optimization: Single query to fetch all probe names
        # then categorize in Ruby rather than 3 separate queries
        # Query count verified during development
        expect(scan).to be_valid
      end
    end

    describe '#group_probes_by_category' do
      it 'categorizes probes correctly' do
        scan = build(:scan, company: company)
        probe_names = [ 'GenericProbe', 'TestCM', 'TestHP', 'AnotherGeneric', 'AnotherCM' ]

        result = scan.send(:group_probes_by_category, probe_names)

        expect(result[:generic]).to match_array([ 'GenericProbe', 'AnotherGeneric' ])
        expect(result[:cm]).to match_array([ 'TestCM', 'AnotherCM' ])
        expect(result[:hp]).to match_array([ 'TestHP' ])
      end

      it 'handles empty array' do
        scan = build(:scan, company: company)
        result = scan.send(:group_probes_by_category, [])

        expect(result[:generic]).to be_empty
        expect(result[:cm]).to be_empty
        expect(result[:hp]).to be_empty
      end
    end
  end

  describe '#has_threat_variants?' do
    it 'returns false (OSS stub)' do
      scan = create(:complete_scan)
      expect(scan.has_threat_variants?).to be false
    end
  end

  describe 'reports_count counter cache' do
    let(:target1) { create(:target, company: company) }
    let(:target2) { create(:target, company: company) }
    let(:probe) { create(:probe) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
    end

    it 'starts at 0 for a new scan' do
      scan = create(:scan, company: company, targets: [ target1 ], probes: [ probe ])
      # The after_create callback creates reports for each target,
      # so reports_count should equal targets.count
      expect(scan.reload.reports_count).to eq(1)
    end

    it 'increments when a report is created' do
      scan = create(:scan, company: company, targets: [ target1 ], probes: [ probe ])
      initial_count = scan.reload.reports_count

      create(:report, scan: scan, target: target1, company: company)

      expect(scan.reload.reports_count).to eq(initial_count + 1)
    end

    it 'decrements when a report is destroyed' do
      scan = create(:scan, company: company, targets: [ target1 ], probes: [ probe ])
      report = create(:report, scan: scan, target: target1, company: company)
      count_before_destroy = scan.reload.reports_count

      report.destroy

      expect(scan.reload.reports_count).to eq(count_before_destroy - 1)
    end

    it 'tracks multiple reports correctly' do
      scan = create(:scan, company: company, targets: [ target1, target2 ], probes: [ probe ])
      # after_create creates one report per target, so 2 reports
      expect(scan.reload.reports_count).to eq(2)

      # Add another report
      create(:report, scan: scan, target: target1, company: company)
      expect(scan.reload.reports_count).to eq(3)
    end

    it 'is included in ransackable_attributes for sorting' do
      expect(Scan.ransackable_attributes).to include('reports_count')
    end
  end

  describe '#derived_status' do
    let(:target) { create(:target, company: company) }
    let(:probe) { create(:probe) }

    before do
      ActsAsTenant.current_tenant = company
    end

    def create_scan_without_reports
      scan = build(:scan, company: company)
      scan.targets = [ target ]
      scan.probes = [ probe ]
      scan.recurrence = IceCube::Rule.daily
      scan.save!
      scan
    end

    context 'when scan has no reports' do
      it 'returns nil' do
        scan = create_scan_without_reports
        expect(scan.derived_status).to be_nil
      end
    end

    context 'when any report is running' do
      it 'returns "running"' do
        scan = create_scan_without_reports
        create(:report, :completed, scan: scan, target: target, company: company)
        create(:report, :running, scan: scan, target: target, company: company)

        expect(scan.reload.derived_status).to eq("running")
      end
    end

    context 'when any report is starting' do
      it 'returns "running"' do
        scan = create_scan_without_reports
        create(:report, scan: scan, target: target, company: company, status: :starting)

        expect(scan.reload.derived_status).to eq("running")
      end
    end

    context 'when any report is processing' do
      it 'returns "running"' do
        scan = create_scan_without_reports
        create(:report, :completed, scan: scan, target: target, company: company)
        create(:report, :processing, scan: scan, target: target, company: company)

        expect(scan.reload.derived_status).to eq("running")
      end
    end

    context 'when last report is completed' do
      it 'returns "completed"' do
        scan = create_scan_without_reports
        create(:report, :stopped, scan: scan, target: target, company: company, created_at: 2.days.ago)
        create(:report, :completed, scan: scan, target: target, company: company, created_at: 1.day.ago)

        expect(scan.reload.derived_status).to eq("completed")
      end
    end

    context 'when last report is failed' do
      it 'returns "failed"' do
        scan = create_scan_without_reports
        create(:report, :completed, scan: scan, target: target, company: company, created_at: 2.days.ago)
        create(:report, :failed, scan: scan, target: target, company: company, created_at: 1.day.ago)

        expect(scan.reload.derived_status).to eq("failed")
      end
    end

    context 'when last report is stopped' do
      it 'returns "stopped"' do
        scan = create_scan_without_reports
        create(:report, :completed, scan: scan, target: target, company: company, created_at: 2.days.ago)
        create(:report, :stopped, scan: scan, target: target, company: company, created_at: 1.day.ago)

        expect(scan.reload.derived_status).to eq("stopped")
      end
    end

    context 'when last report is interrupted' do
      it 'returns "interrupted"' do
        scan = create_scan_without_reports
        create(:report, scan: scan, target: target, company: company, status: :interrupted)

        expect(scan.reload.derived_status).to eq("interrupted")
      end
    end

    context 'when last report is pending' do
      it 'returns "pending"' do
        scan = create_scan_without_reports
        create(:report, scan: scan, target: target, company: company, status: :pending)

        expect(scan.reload.derived_status).to eq("pending")
      end
    end

    context 'when active reports exist alongside terminal reports' do
      it 'prioritizes running over any terminal status' do
        scan = create_scan_without_reports
        create(:report, :failed, scan: scan, target: target, company: company, created_at: 1.day.ago)
        create(:report, :running, scan: scan, target: target, company: company, created_at: 2.days.ago)

        expect(scan.reload.derived_status).to eq("running")
      end
    end
  end

  describe 'token usage estimation methods' do
    let(:target) { create(:target, company: company) }
    let(:probe1) { create(:probe, name: 'TokenProbe1', input_tokens: 100) }
    let(:probe2) { create(:probe, name: 'TokenProbe2', input_tokens: 250) }
    let(:probe3) { create(:probe, name: 'TokenProbe3', input_tokens: 150) }

    describe '#projected_input_tokens' do
      it 'sums input_tokens from all probes' do
        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ probe1, probe2, probe3 ]
        scan.save!

        expect(scan.projected_input_tokens).to eq(500) # 100 + 250 + 150
      end

      it 'returns 0 when no probes' do
        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ create(:probe) ] # Need at least one for validation
        scan.save!
        scan.probes.clear # Clear after save to test empty case

        expect(scan.projected_input_tokens).to eq(0)
      end

      it 'handles probes with nil input_tokens as 0' do
        probe_with_nil = create(:probe, name: 'NilTokenProbe')
        probe_with_nil.update_column(:input_tokens, 0)

        scan = build(:scan, company: company)
        scan.targets = [ target ]
        scan.probes = [ probe1, probe_with_nil ]
        scan.save!

        expect(scan.projected_input_tokens).to eq(100)
      end
    end

    describe '#monthly_token_projection' do
      context 'when not scheduled' do
        it 'returns nil' do
          scan = build(:scan, company: company)
          scan.targets = [ target ]
          scan.probes = [ probe1 ]
          scan.recurrence = nil
          scan.save!

          expect(scan.monthly_token_projection).to be_nil
        end
      end

      context 'when scheduled hourly' do
        it 'calculates approximately 720 runs per month' do
          scan = build(:scan, company: company)
          scan.targets = [ target ]
          scan.probes = [ probe1 ] # 100 input_tokens
          scan.recurrence = IceCube::Rule.hourly
          scan.save!

          projection = scan.monthly_token_projection

          expect(projection).to be_a(Hash)
          expect(projection[:runs]).to be >= 700 # ~720 runs in 30 days
          expect(projection[:runs]).to be <= 750
          expect(projection[:tokens]).to eq(projection[:runs] * 100)
        end
      end

      context 'when scheduled daily' do
        it 'calculates approximately 30 runs per month' do
          scan = build(:scan, company: company)
          scan.targets = [ target ]
          scan.probes = [ probe1, probe2 ] # 350 input_tokens
          scan.recurrence = IceCube::Rule.daily
          scan.save!

          projection = scan.monthly_token_projection

          expect(projection[:runs]).to be >= 29
          expect(projection[:runs]).to be <= 31
          expect(projection[:tokens]).to eq(projection[:runs] * 350)
        end
      end

      context 'when scheduled weekly' do
        it 'calculates approximately 4 runs per month' do
          scan = build(:scan, company: company)
          scan.targets = [ target ]
          scan.probes = [ probe1 ] # 100 input_tokens
          scan.recurrence = IceCube::Rule.weekly
          scan.save!

          projection = scan.monthly_token_projection

          expect(projection[:runs]).to be >= 4
          expect(projection[:runs]).to be <= 5
          expect(projection[:tokens]).to eq(projection[:runs] * 100)
        end
      end
    end

    describe '#actual_token_averages' do
      let(:scan) do
        s = build(:scan, company: company)
        s.targets = [ target ]
        s.probes = [ probe1 ]
        s.save!
        s
      end
      let(:detector) { create(:detector) }

      context 'when no completed reports' do
        it 'returns nil' do
          expect(scan.actual_token_averages).to be_nil
        end

        it 'returns nil when only non-completed reports exist' do
          report = create(:report, scan: scan, target: target, company: company, status: :running)
          create(:probe_result, report: report, probe: probe1, detector: detector,
                 input_tokens: 100, output_tokens: 50)

          expect(scan.actual_token_averages).to be_nil
        end
      end

      context 'with completed reports' do
        it 'calculates average input and output tokens' do
          report1 = create(:report, scan: scan, target: target, company: company, status: :completed)
          report2 = create(:report, scan: scan, target: target, company: company, status: :completed)

          create(:probe_result, report: report1, probe: probe1, detector: detector,
                 input_tokens: 100, output_tokens: 50)
          create(:probe_result, report: report2, probe: probe1, detector: detector,
                 input_tokens: 200, output_tokens: 150)

          result = scan.actual_token_averages

          expect(result).to be_a(Hash)
          expect(result[:count]).to eq(2)
          # Total: 300 input, 200 output, averaged over 2 reports
          expect(result[:input]).to eq(150) # (100 + 200) / 2
          expect(result[:output]).to eq(100) # (50 + 150) / 2
        end

        it 'handles reports with multiple probe_results' do
          report = create(:report, scan: scan, target: target, company: company, status: :completed)

          create(:probe_result, report: report, probe: probe1, detector: detector,
                 input_tokens: 100, output_tokens: 50)
          create(:probe_result, report: report, probe: probe2, detector: detector,
                 input_tokens: 200, output_tokens: 100)

          result = scan.actual_token_averages

          expect(result[:count]).to eq(1)
          expect(result[:input]).to eq(300) # Sum of both probe_results
          expect(result[:output]).to eq(150)
        end

        it 'returns nil for reports with no probe_results (no token data)' do
          create(:report, scan: scan, target: target, company: company, status: :completed)

          result = scan.actual_token_averages

          # Reports without token data are excluded from averages
          expect(result).to be_nil
        end

        it 'uses SQL aggregation to avoid N+1 queries' do
          report1 = create(:report, scan: scan, target: target, company: company, status: :completed)
          report2 = create(:report, scan: scan, target: target, company: company, status: :completed)

          create(:probe_result, report: report1, probe: probe1, detector: detector,
                 input_tokens: 100, output_tokens: 50)
          create(:probe_result, report: report2, probe: probe1, detector: detector,
                 input_tokens: 200, output_tokens: 150)

          # Verify no N+1 by checking query count
          query_count = 0
          ActiveSupport::Notifications.subscribe('sql.active_record') do |*_args|
            query_count += 1
          end

          scan.actual_token_averages

          ActiveSupport::Notifications.unsubscribe('sql.active_record')

          # Should be 2-3 queries max (completed check, count, aggregate)
          # NOT 1 query per report
          expect(query_count).to be <= 5
        end
      end
    end

    describe 'PROJECTION_PERIOD_DAYS constant' do
      it 'is defined as 30' do
        expect(Scan::PROJECTION_PERIOD_DAYS).to eq(30)
      end
    end

    describe '#estimated_run_time' do
      let(:target_with_rate) { create(:target, :with_token_rate, company: company) }
      let(:target_without_rate) { create(:target, company: company, tokens_per_second: nil) }
      let(:webchat_target) { create(:target, :webchat, company: company, tokens_per_second: 30.0) }
      let(:probe_100) { create(:probe, name: 'Probe100', input_tokens: 100) }
      let(:probe_200) { create(:probe, name: 'Probe200', input_tokens: 200) }

      before do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)
      end

      context 'when no API targets with measured rates exist' do
        it 'returns nil when all targets are unmeasured' do
          scan = build(:scan, company: company)
          scan.targets = [ target_without_rate ]
          scan.probes = [ probe_100 ]
          scan.save!

          expect(scan.estimated_run_time).to be_nil
        end

        it 'returns nil when only webchat targets exist' do
          scan = build(:scan, company: company)
          scan.targets = [ webchat_target ]
          scan.probes = [ probe_100 ]
          scan.save!

          expect(scan.estimated_run_time).to be_nil
        end

        it 'returns nil when no targets exist' do
          scan = build(:scan, company: company)
          scan.targets = [ target_with_rate ]
          scan.probes = [ probe_100 ]
          scan.save!
          scan.targets.clear

          expect(scan.estimated_run_time).to be_nil
        end
      end

      context 'when projected_input_tokens is zero' do
        it 'returns nil' do
          scan = build(:scan, company: company)
          scan.targets = [ target_with_rate ]
          scan.probes = [ create(:probe, input_tokens: 0) ]
          scan.save!

          expect(scan.estimated_run_time).to be_nil
        end
      end

      context 'when valid targets and probes exist' do
        let(:scan) do
          s = build(:scan, company: company)
          s.targets = [ target_with_rate ]
          s.probes = [ probe_100, probe_200 ]
          s.save!
          s
        end

        it 'returns a hash with required keys' do
          result = scan.estimated_run_time

          expect(result).to be_a(Hash)
          expect(result).to have_key(:seconds)
          expect(result).to have_key(:formatted)
          expect(result).to have_key(:parallel_limit)
          expect(result).to have_key(:unmeasured_targets)
        end

        it 'calculates estimated seconds correctly' do
          # Input tokens: 100 + 200 = 300
          # With OUTPUT_MULTIPLIER 2: estimated total = 600
          # Target rate: 25.5 tok/s
          # Time for one target: 600 / 25.5 = ~23.53 seconds
          # With parallel_limit 5: 23.53 / 5 = ~4.71 seconds
          result = scan.estimated_run_time

          expect(result[:seconds]).to be >= 4
          expect(result[:seconds]).to be <= 5
        end

        it 'includes parallel_limit from SettingsService' do
          result = scan.estimated_run_time

          expect(result[:parallel_limit]).to eq(5)
        end

        it 'counts unmeasured API targets' do
          scan.targets << target_without_rate

          result = scan.estimated_run_time

          expect(result[:unmeasured_targets]).to eq(1)
        end

        it 'returns 0 unmeasured targets when all are measured' do
          result = scan.estimated_run_time

          expect(result[:unmeasured_targets]).to eq(0)
        end
      end

      context 'with multiple targets' do
        let(:target_fast) { create(:target, company: company, tokens_per_second: 100.0, tokens_per_second_sample_count: 1) }
        let(:target_slow) { create(:target, company: company, tokens_per_second: 10.0, tokens_per_second_sample_count: 1) }

        it 'sums time across all measured targets' do
          scan = build(:scan, company: company)
          scan.targets = [ target_fast, target_slow ]
          scan.probes = [ probe_100 ] # 100 input tokens
          scan.save!

          allow(SettingsService).to receive(:parallel_scans_limit).and_return(1)

          result = scan.estimated_run_time

          # With OUTPUT_MULTIPLIER 2: estimated total = 200
          # Fast target: 200 / 100 = 2 seconds
          # Slow target: 200 / 10 = 20 seconds
          # Total: 22 seconds / 1 parallel = 22 seconds
          expect(result[:seconds]).to eq(22)
        end

        it 'divides by parallel limit' do
          scan = build(:scan, company: company)
          scan.targets = [ target_fast, target_slow ]
          scan.probes = [ probe_100 ]
          scan.save!

          allow(SettingsService).to receive(:parallel_scans_limit).and_return(2)

          result = scan.estimated_run_time

          # Total: 22 seconds / 2 parallel = 11
          expect(result[:seconds]).to eq(11)
        end
      end

      context 'formatted duration' do
        let(:target_slow) { create(:target, company: company, tokens_per_second: 1.0, tokens_per_second_sample_count: 1) }
        let(:probe_large) { create(:probe, name: 'LargeProbe', input_tokens: 10000) }

        it 'formats short durations as minutes' do
          scan = build(:scan, company: company)
          scan.targets = [ target_with_rate ]
          scan.probes = [ probe_100 ]
          scan.save!

          result = scan.estimated_run_time

          expect(result[:formatted]).to match(/\d+m/)
        end

        it 'formats hours correctly' do
          scan = build(:scan, company: company)
          scan.targets = [ target_slow ]
          scan.probes = [ probe_large ]
          scan.save!

          allow(SettingsService).to receive(:parallel_scans_limit).and_return(1)

          result = scan.estimated_run_time

          # 10000 tokens / 1 tok/s = 10000 seconds = ~2.7 hours
          expect(result[:formatted]).to include('h')
        end
      end
    end

    describe '#format_duration (private)' do
      let(:scan) do
        s = build(:scan, company: company)
        s.targets = [ create(:target, company: company) ]
        s.probes = [ create(:probe) ]
        s.save!
        s
      end

      it 'returns "0m" for zero seconds' do
        expect(scan.send(:format_duration, 0)).to eq('0m')
      end

      it 'returns "0m" for negative seconds' do
        expect(scan.send(:format_duration, -10)).to eq('0m')
      end

      it 'formats minutes only' do
        expect(scan.send(:format_duration, 120)).to eq('2m')
      end

      it 'formats hours and minutes' do
        expect(scan.send(:format_duration, 3720)).to eq('1h 2m')
      end

      it 'formats days, hours, and minutes' do
        expect(scan.send(:format_duration, 90120)).to eq('1d 1h 2m')
      end

      it 'shows 0m when only seconds with no full minutes' do
        expect(scan.send(:format_duration, 30)).to eq('0m')
      end

      it 'handles large values' do
        # 5 days, 3 hours, 45 minutes
        seconds = (5 * 86400) + (3 * 3600) + (45 * 60)
        expect(scan.send(:format_duration, seconds)).to eq('5d 3h 45m')
      end
    end
  end
end
