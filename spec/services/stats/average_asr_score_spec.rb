require 'rails_helper'

RSpec.describe Stats::AverageAsrScore do
  # The aggregate is tenant-scoped (acts_as_tenant), so run within a tenant; records
  # created by the factories below then belong to this company and are counted.
  let(:company) { create(:company) }
  around { |example| ActsAsTenant.with_tenant(company) { example.run } }

  let(:detector) { create(:detector) }
  let(:target) { create(:target) }
  let(:scan) { create(:complete_scan) }
  let(:probe) { create(:probe) }

  describe '#call' do
    # Factories can reset ActsAsTenant.current_tenant during record creation, so set the
    # tenant explicitly at call time (the aggregate is tenant-scoped).
    subject { ActsAsTenant.with_tenant(company) { described_class.new(days: 30).call } }

    context 'when a report holds only partial results' do
      # A scan that died mid-run leaves real but incomplete evidence. Averaging it
      # with finished scans silently mixes partial data into a headline number, so
      # partial reports are excluded from the aggregate entirely.
      let!(:complete_report) do
        create(:report, scan: scan, target: target, company: company,
                        status: :completed, result_completeness: :complete).tap do |report|
          create(:probe_result, report: report, probe: probe, detector: detector, passed: 4, total: 10)
        end
      end

      let!(:partial_report) do
        create(:report, scan: scan, target: target, company: company,
                        status: :failed, result_completeness: :partial).tap do |report|
          create(:probe_result, report: report, probe: probe, detector: detector, passed: 10, total: 10)
        end
      end

      it 'excludes the partial report from the average' do
        # Both included would average (40 + 100) / 2 = 70.0
        expect(subject[:score]).to eq(40.0)
      end

      it 'excludes the partial report from the time series' do
        rates = subject[:data][:rates].reject(&:zero?)

        expect(rates).to all eq(40.0)
      end
    end

    context 'when a terminal report was never classified' do
      # The hook classifies every terminal transition and the migration classifies
      # history, but an old worker finishing mid-rollout writes neither. Such a row may
      # hold partial evidence, so it is left out rather than counted on the assumption
      # that unset means whole.
      let!(:complete_report) do
        create(:report, scan: scan, target: target, company: company,
                        status: :completed, result_completeness: :complete).tap do |report|
          create(:probe_result, report: report, probe: probe, detector: detector, passed: 4, total: 10)
        end
      end

      it 'excludes an unclassified failed report' do
        unclassified = create(:report, scan: scan, target: target, company: company, status: :failed)
        create(:probe_result, report: unclassified, probe: probe, detector: detector, passed: 10, total: 10)
        unclassified.update_columns(result_completeness: nil)

        # Counted it would average (40 + 100) / 2 = 70.0
        expect(subject[:score]).to eq(40.0)
      end

      it 'still counts an unclassified completed report' do
        # A finished run is complete unless a recorded plan says otherwise, which is what
        # the model derives for it too -- so dropping it would discard good data.
        unclassified = create(:report, scan: scan, target: target, company: company, status: :completed)
        create(:probe_result, report: unclassified, probe: probe, detector: detector, passed: 10, total: 10)
        unclassified.update_columns(result_completeness: nil)

        expect(subject[:score]).to eq(70.0)
      end
    end

    context 'when a report reaches a terminal state outside Reports::Process' do
      # A stop records completeness through the Report hook, so the aggregate only has to
      # read the column -- it does not restate the rule in SQL. This is the end-to-end
      # proof of that: stop a run holding partial results and it leaves the average.
      let!(:complete_report) do
        create(:report, scan: scan, target: target, company: company,
                        status: :completed, result_completeness: :complete).tap do |report|
          create(:probe_result, report: report, probe: probe, detector: detector, passed: 4, total: 10)
        end
      end

      it 'excludes a stopped run that kept only some of its results' do
        stopped = create(:report, scan: scan, target: target, company: company, status: :running,
                                  planned_probe_count: 5)
        create(:probe_result, report: stopped, probe: probe, detector: detector, passed: 10, total: 10)
        stopped.update!(status: :stopped)

        expect(stopped.reload.result_completeness).to eq('partial')
        # Counted it would average (40 + 100) / 2 = 70.0
        expect(subject[:score]).to eq(40.0)
      end

      it 'still counts a stopped run that produced everything it planned' do
        stopped = create(:report, scan: scan, target: target, company: company, status: :running,
                                  planned_probe_count: 1)
        create(:probe_result, report: stopped, probe: probe, detector: detector, passed: 10, total: 10)
        stopped.update!(status: :stopped)

        expect(stopped.reload.result_completeness).to eq('complete')
        expect(subject[:score]).to eq(70.0)
      end
    end

    context 'when no reports exist' do
      it 'returns zero score with empty data' do
        result = subject

        expect(result[:score]).to eq(0)
        expect(result[:data][:dates]).to be_present
        expect(result[:data][:rates]).to all eq(0.0)
      end
    end

    context 'when reports exist with probe results' do
      before do
        report1 = create(:report, company: company, target: target, scan: scan, created_at: Time.zone.today)
        create(:probe_result, report: report1, probe: probe, detector: detector, passed: 5, total: 10)

        report2 = create(:report, company: company, target: target, scan: scan, created_at: 5.days.ago)
        create(:probe_result, report: report2, probe: probe, detector: detector, passed: 7, total: 10)

        report3 = create(:report, company: company, target: target, scan: scan, created_at: 15.days.ago)
        create(:probe_result, report: report3, probe: probe, detector: detector, passed: 3, total: 10)
      end

      it 'returns the average of all report success rates' do
        result = subject

        expect(result[:score]).to eq(50)
      end

      it 'includes time series data for the entire period' do
        result = subject

        # Should have dates for 30 days
        expect(result[:data][:dates].length).to eq(31) # Current day + 30 previous days
        expect(result[:data][:rates].length).to eq(31)

        # Check rates for days with data
        today_index = 30 # Last entry in the array
        expect(result[:data][:rates][today_index]).to eq(50.0)

        days_ago_5_index = 25 # 30 - 5
        expect(result[:data][:rates][days_ago_5_index]).to eq(70.0)

        days_ago_15_index = 15 # 30 - 15
        expect(result[:data][:rates][days_ago_15_index]).to eq(30.0)

        # Other days should be 0
        other_days = result[:data][:rates].select.with_index { |_, i| ![ today_index, days_ago_5_index, days_ago_15_index ].include?(i) }
        expect(other_days).to all eq(0.0)
      end
    end

    context 'with reports outside the specified time window' do
      before do
        report_recent = create(:report, company: company, target: target, scan: scan, created_at: 10.days.ago)
        create(:probe_result, report: report_recent, probe: probe, detector: detector, passed: 6, total: 10)

        report_old = create(:report, company: company, target: target, scan: scan, created_at: 35.days.ago)
        create(:probe_result, report: report_old, probe: probe, detector: detector, passed: 4, total: 10)
      end

      it 'only includes reports within the time window' do
        result = subject

        expect(result[:score]).to eq(60)
      end
    end

    context 'with reports with zero total probes' do
      before do
        report = create(:report, company: company, target: target, scan: scan, created_at: Time.zone.today)
        create(:probe_result, report: report, probe: probe, detector: detector, passed: 0, total: 0)
      end

      it 'excludes reports with zero totals from calculation' do
        result = subject

        expect(result[:score]).to eq(0)
      end
    end
  end

  describe '#average_attack_success_rate' do
    subject { described_class.new }

    context 'with various success rates' do
      before do
        report1 = create(:report, company: company, target: target, scan: scan, created_at: 1.day.ago)
        create(:probe_result, report: report1, probe: probe, detector: detector, passed: 8, total: 10)

        report2 = create(:report, company: company, target: target, scan: scan, created_at: 2.days.ago)
        create(:probe_result, report: report2, probe: probe, detector: detector, passed: 4, total: 10)

        report3 = create(:report, company: company, target: target, scan: scan, created_at: 3.days.ago)
        create(:probe_result, report: report3, probe: probe, detector: detector, passed: 6, total: 10)
      end

      it 'calculates the average correctly' do
        ActsAsTenant.with_tenant(company) do
          expect(subject.average_attack_success_rate(4.days.ago)).to eq(60)
        end
      end
    end

    context 'with no reports' do
      it 'returns zero' do
        ActsAsTenant.with_tenant(company) do
          expect(subject.average_attack_success_rate(4.days.ago)).to eq(0)
        end
      end
    end
  end

  describe '#average_attack_success_rate_over_time' do
    subject { described_class.new }

    context 'with daily interval' do
      before do
        report1 = create(:report, company: company, target: target, scan: scan, created_at: Time.zone.today)
        create(:probe_result, report: report1, probe: probe, detector: detector, passed: 5, total: 10)

        report2 = create(:report, company: company, target: target, scan: scan, created_at: 1.day.ago)
        create(:probe_result, report: report2, probe: probe, detector: detector, passed: 7, total: 10)
      end

      it 'returns data grouped by day' do
        result = ActsAsTenant.with_tenant(company) { subject.average_attack_success_rate_over_time(2.days.ago) }

        expect(result[:rates]).to eq([ 0.0, 70.0, 50.0 ])
      end
    end

    context 'with weekly interval' do
      before do
        report1 = create(:report, company: company, target: target, scan: scan, created_at: Time.zone.today)
        create(:probe_result, report: report1, probe: probe, detector: detector, passed: 6, total: 10)

        last_week = 1.week.ago
        report2 = create(:report, company: company, target: target, scan: scan, created_at: last_week)
        create(:probe_result, report: report2, probe: probe, detector: detector, passed: 8, total: 10)
      end

      it 'returns data grouped by week' do
        result = ActsAsTenant.with_tenant(company) { subject.average_attack_success_rate_over_time(2.weeks.ago, "week") }

        this_week_label = "#{Time.zone.today.to_date.cwyear}-Week #{Time.zone.today.strftime('%V')}"
        last_week_label = "#{1.week.ago.to_date.cwyear}-Week #{1.week.ago.strftime('%V')}"

        this_week_index = result[:dates].find_index(this_week_label)
        last_week_index = result[:dates].find_index(last_week_label)

        expect(result[:rates][this_week_index]).to eq(60.0)
        expect(result[:rates][last_week_index]).to eq(80.0)
      end
    end

    context 'with monthly interval' do
      before do
        report = create(:report, company: company, target: target, scan: scan, created_at: Time.zone.today)
        create(:probe_result, report: report, probe: probe, detector: detector, passed: 75, total: 100)
      end

      it 'returns data grouped by month' do
        result = ActsAsTenant.with_tenant(company) { subject.average_attack_success_rate_over_time(1.month.ago, "month") }

        this_month_label = Time.zone.today.strftime("%Y-%m")
        this_month_index = result[:dates].find_index(this_month_label)

        expect(result[:rates][this_month_index]).to eq(75.0)
      end
    end
  end
end
