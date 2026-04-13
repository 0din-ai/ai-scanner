require 'rails_helper'

RSpec.describe Scans::StatsSerializer, type: :service do
  let(:target) { create(:target, :good, name: "Test Target", model_type: "OpenAIGenerator", model: "gpt-4") }
  let(:default_probe) { create(:probe) }
  let(:scan) { create(:scan, name: "Test Scan", targets: [ target ], probes: [ default_probe ]) }
  let(:serializer) { described_class.new(scan) }

  describe '#call' do
    context 'when scan has no completed reports' do
      it 'returns all expected keys' do
        result = serializer.call

        expect(result).to have_key(:scan)
        expect(result).to have_key(:stats)
        expect(result).to have_key(:models)
        expect(result).to have_key(:successful_attacks)
        expect(result).to have_key(:schedule)
        expect(result).to have_key(:token_usage)
        expect(result).to have_key(:risk_distribution)
        expect(result).to have_key(:disclosure_breakdown)
        expect(result).to have_key(:top_vulnerabilities)
        expect(result).to have_key(:detector_breakdown)
        expect(result).to have_key(:coverage_metrics)
        expect(result).to have_key(:security_grade)
        expect(result).to have_key(:trend_data)
      end

      it 'returns empty collections for marketing fields' do
        result = serializer.call

        expect(result[:risk_distribution]).to eq({})
        expect(result[:disclosure_breakdown]).to eq({})
        expect(result[:top_vulnerabilities]).to eq([])
        expect(result[:detector_breakdown]).to eq([])
      end
    end

    context 'when scan has completed reports with data' do
      let(:detector) { create(:detector, name: "TestDetector") }
      let(:probe) { create(:probe, :with_detector, social_impact_score: "Critical Risk", disclosure_status: "0-day") }
      let!(:report) { create(:report, :completed, scan: scan, target: target) }
      let!(:probe_result) { create(:probe_result, report: report, probe: probe, detector: detector, passed: 5, total: 10) }
      let!(:detector_result) { create(:detector_result, report: report, detector: detector, passed: 5, total: 10) }

      before do
        scan.probes << probe
      end

      it 'returns populated marketing fields' do
        result = serializer.call

        expect(result[:risk_distribution]).not_to be_empty
        expect(result[:top_vulnerabilities]).not_to be_empty
        expect(result[:detector_breakdown]).not_to be_empty
      end
    end
  end

  describe '#scan_info' do
    it 'returns scan identification data' do
      result = serializer.send(:scan_info)

      expect(result[:id]).to eq(scan.id)
      expect(result[:uuid]).to eq(scan.uuid)
      expect(result[:name]).to eq("Test Scan")
      expect(result[:created_at]).to be_present
      expect(result[:updated_at]).to be_present
    end

    it 'formats dates as ISO8601' do
      result = serializer.send(:scan_info)

      expect(result[:created_at]).to match(/^\d{4}-\d{2}-\d{2}T/)
      expect(result[:updated_at]).to match(/^\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe '#models_info' do
    it 'returns target/model information' do
      result = serializer.send(:models_info)

      expect(result).to be_an(Array)
      expect(result.first).to include(
        target_id: target.id,
        target_name: "Test Target",
        model_type: "OpenAIGenerator",
        model: "gpt-4"
      )
    end

    context 'with multiple targets' do
      let(:target2) { create(:target, :good, name: "Target 2", model: "claude-3") }

      before do
        scan.targets << target2
        scan.save!
      end

      it 'returns all targets' do
        result = serializer.send(:models_info)

        expect(result.length).to eq(2)
        expect(result.map { |t| t[:target_name] }).to contain_exactly("Test Target", "Target 2")
      end
    end
  end

  describe '#attacks_info' do
    context 'with multiple targets' do
      let(:target2) { create(:target, :good, name: "Target 2", model: "claude-3") }
      let(:detector) { create(:detector) }
      let(:probe) { create(:probe, detector: detector) }

      before do
        scan.targets << target2
        scan.probes << probe

        report1 = create(:report, :completed, scan: scan, target: target)
        report2 = create(:report, :completed, scan: scan, target: target2)

        create(:detector_result, report: report1, detector: detector, passed: 10, total: 50)
        create(:detector_result, report: report2, detector: detector, passed: 20, total: 80)
      end

      it 'returns correct per-target totals from a single grouped query' do
        result = serializer.send(:attacks_info)

        expect(result[:total_passed]).to eq(30)
        expect(result[:total_tests]).to eq(130)

        by_target = result[:by_target]
        expect(by_target.length).to eq(2)

        t1 = by_target.find { |t| t[:target_name] == "Test Target" }
        t2 = by_target.find { |t| t[:target_name] == "Target 2" }

        expect(t1[:passed]).to eq(10)
        expect(t1[:total]).to eq(50)
        expect(t1[:asr]).to eq(20.0)

        expect(t2[:passed]).to eq(20)
        expect(t2[:total]).to eq(80)
        expect(t2[:asr]).to eq(25.0)
      end

      it 'includes targets with no completed reports as zero' do
        target3 = create(:target, :good, name: "Target 3")
        scan.targets << target3

        result = serializer.send(:attacks_info)
        t3 = result[:by_target].find { |t| t[:target_name] == "Target 3" }

        expect(t3[:passed]).to eq(0)
        expect(t3[:total]).to eq(0)
        expect(t3[:asr]).to eq(0)
      end
    end
  end

  describe '#risk_distribution_info' do
    context 'when there are no completed reports' do
      it 'returns an empty hash' do
        expect(serializer.send(:risk_distribution_info)).to eq({})
      end
    end

    context 'when there are completed reports with probe results' do
      let(:detector) { create(:detector) }

      let(:critical_probe) { create(:probe, social_impact_score: "Critical Risk", detector: detector) }
      let(:high_probe) { create(:probe, social_impact_score: "High Risk", detector: detector) }
      let(:moderate_probe) { create(:probe, social_impact_score: "Moderate Risk", detector: detector) }

      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      before do
        scan.probes << [ critical_probe, high_probe, moderate_probe ]

        create(:probe_result, report: report, probe: critical_probe, detector: detector, passed: 3, total: 10)
        create(:probe_result, report: report, probe: high_probe, detector: detector, passed: 2, total: 10)
        create(:probe_result, report: report, probe: moderate_probe, detector: detector, passed: 0, total: 10)
      end

      it 'returns risk distribution grouped by social_impact_score' do
        result = serializer.send(:risk_distribution_info)

        expect(result).to have_key("critical_risk")
        expect(result).to have_key("high_risk")
        expect(result).to have_key("moderate_risk")
      end

      it 'includes correct counts for each risk level' do
        result = serializer.send(:risk_distribution_info)

        expect(result["critical_risk"][:probes_tested]).to eq(1)
        expect(result["critical_risk"][:passed]).to eq(3)
        expect(result["critical_risk"][:total]).to eq(10)
        expect(result["critical_risk"][:asr]).to eq(30.0)
      end

      it 'calculates ASR correctly' do
        result = serializer.send(:risk_distribution_info)

        expect(result["high_risk"][:asr]).to eq(20.0)  # 2/10 = 20%
        expect(result["moderate_risk"][:asr]).to eq(0)  # 0/10 = 0%
      end
    end

    context 'when probes have no social_impact_score' do
      let(:detector) { create(:detector) }
      let(:probe_no_score) { create(:probe, social_impact_score: nil, detector: detector) }
      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      before do
        scan.probes << probe_no_score
        create(:probe_result, report: report, probe: probe_no_score, detector: detector, passed: 1, total: 5)
      end

      it 'excludes probes with nil social_impact_score' do
        result = serializer.send(:risk_distribution_info)

        # Should not include any entries since the only probe has nil score
        expect(result.keys).not_to include(nil)
      end
    end
  end

  describe '#disclosure_breakdown_info' do
    context 'when there are no completed reports' do
      it 'returns an empty hash' do
        expect(serializer.send(:disclosure_breakdown_info)).to eq({})
      end
    end

    context 'when there are completed reports with probe results' do
      let(:detector) { create(:detector) }

      let(:zero_day_probe) { create(:probe, disclosure_status: "0-day", detector: detector) }
      let(:n_day_probe) { create(:probe, disclosure_status: "n-day", detector: detector) }

      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      before do
        scan.probes << [ zero_day_probe, n_day_probe ]

        create(:probe_result, report: report, probe: zero_day_probe, detector: detector, passed: 5, total: 20)
        create(:probe_result, report: report, probe: n_day_probe, detector: detector, passed: 3, total: 15)
      end

      it 'returns breakdown by disclosure status' do
        result = serializer.send(:disclosure_breakdown_info)

        expect(result).to have_key("zero_day")
        expect(result).to have_key("n_day")
      end

      it 'includes correct counts for zero-day probes' do
        result = serializer.send(:disclosure_breakdown_info)

        expect(result["zero_day"][:probes_tested]).to eq(1)
        expect(result["zero_day"][:passed]).to eq(5)
        expect(result["zero_day"][:total]).to eq(20)
        expect(result["zero_day"][:asr]).to eq(25.0)
      end

      it 'includes correct counts for n-day probes' do
        result = serializer.send(:disclosure_breakdown_info)

        expect(result["n_day"][:probes_tested]).to eq(1)
        expect(result["n_day"][:passed]).to eq(3)
        expect(result["n_day"][:total]).to eq(15)
        expect(result["n_day"][:asr]).to eq(20.0)
      end
    end
  end

  describe '#top_vulnerabilities_info' do
    context 'when there are no completed reports' do
      it 'returns an empty array' do
        expect(serializer.send(:top_vulnerabilities_info)).to eq([])
      end
    end

    context 'when there are completed reports with successful attacks' do
      let(:detector) { create(:detector) }

      let(:critical_probe) { create(:probe, name: "CriticalProbe", category: "0din", social_impact_score: "Critical Risk", disclosure_status: "0-day", detector: detector) }
      let(:high_probe) { create(:probe, name: "HighProbe", category: "0din", social_impact_score: "High Risk", disclosure_status: "n-day", detector: detector) }
      let(:moderate_probe) { create(:probe, name: "ModerateProbe", category: "0din", social_impact_score: "Moderate Risk", disclosure_status: "n-day", detector: detector) }

      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      before do
        scan.probes << [ critical_probe, high_probe, moderate_probe ]

        # Critical probe with successful attacks
        create(:probe_result, report: report, probe: critical_probe, detector: detector, passed: 8, total: 10)
        # High probe with successful attacks
        create(:probe_result, report: report, probe: high_probe, detector: detector, passed: 5, total: 10)
        # Moderate probe with no successful attacks
        create(:probe_result, report: report, probe: moderate_probe, detector: detector, passed: 0, total: 10)
      end

      it 'returns only probes with successful attacks' do
        result = serializer.send(:top_vulnerabilities_info)

        probe_names = result.map { |v| v[:probe_name] }
        expect(probe_names).to include("CriticalProbe", "HighProbe")
        expect(probe_names).not_to include("ModerateProbe")
      end

      it 'orders by risk level (highest first) then by passed count' do
        result = serializer.send(:top_vulnerabilities_info)

        expect(result.first[:probe_name]).to eq("CriticalProbe")
        expect(result.first[:risk_level]).to eq("Critical Risk")
      end

      it 'includes all expected fields for each vulnerability' do
        result = serializer.send(:top_vulnerabilities_info)
        vulnerability = result.first

        expect(vulnerability).to have_key(:probe_id)
        expect(vulnerability).to have_key(:probe_name)
        expect(vulnerability).to have_key(:category)
        expect(vulnerability).to have_key(:risk_level)
        expect(vulnerability).to have_key(:disclosure_status)
        expect(vulnerability).to have_key(:passed)
        expect(vulnerability).to have_key(:total)
        expect(vulnerability).to have_key(:success_rate)
      end

      it 'calculates success_rate correctly' do
        result = serializer.send(:top_vulnerabilities_info)
        critical = result.find { |v| v[:probe_name] == "CriticalProbe" }

        expect(critical[:success_rate]).to eq(80.0)  # 8/10 = 80%
      end

      it 'limits results to 10' do
        # Create 15 probes with successful attacks
        15.times do |i|
          probe = create(:probe, name: "Probe#{i}", category: "0din", social_impact_score: "High Risk", detector: detector)
          scan.probes << probe
          create(:probe_result, report: report, probe: probe, detector: detector, passed: 5, total: 10)
        end

        result = serializer.send(:top_vulnerabilities_info)

        expect(result.length).to be <= 10
      end
    end
  end

  describe '#detector_breakdown_info' do
    context 'when there are no completed reports' do
      it 'returns an empty array' do
        expect(serializer.send(:detector_breakdown_info)).to eq([])
      end
    end

    context 'when there are completed reports with detector results' do
      let(:detector1) { create(:detector, name: "MitigationBypass") }
      let(:detector2) { create(:detector, name: "CrystalMethScore") }

      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      before do
        create(:detector_result, report: report, detector: detector1, passed: 10, total: 50)
        create(:detector_result, report: report, detector: detector2, passed: 25, total: 100)
      end

      it 'returns all detectors with results' do
        result = serializer.send(:detector_breakdown_info)

        expect(result.length).to eq(2)
        detector_names = result.map { |d| d[:detector_name] }
        expect(detector_names).to contain_exactly("MitigationBypass", "CrystalMethScore")
      end

      it 'includes correct stats for each detector' do
        result = serializer.send(:detector_breakdown_info)
        bypass = result.find { |d| d[:detector_name] == "MitigationBypass" }

        expect(bypass[:passed]).to eq(10)
        expect(bypass[:total]).to eq(50)
        expect(bypass[:asr]).to eq(20.0)
      end

      it 'orders by passed count descending' do
        result = serializer.send(:detector_breakdown_info)

        expect(result.first[:detector_name]).to eq("CrystalMethScore")  # 25 passed > 10 passed
      end
    end

    context 'with multiple reports' do
      let(:detector) { create(:detector, name: "TestDetector") }

      let!(:report1) { create(:report, :completed, scan: scan, target: target) }
      let!(:report2) { create(:report, :completed, scan: scan, target: target) }

      before do
        create(:detector_result, report: report1, detector: detector, passed: 10, total: 50)
        create(:detector_result, report: report2, detector: detector, passed: 15, total: 50)
      end

      it 'aggregates results across all completed reports' do
        result = serializer.send(:detector_breakdown_info)
        test_detector = result.find { |d| d[:detector_name] == "TestDetector" }

        expect(test_detector[:passed]).to eq(25)  # 10 + 15
        expect(test_detector[:total]).to eq(100)  # 50 + 50
        expect(test_detector[:asr]).to eq(25.0)
      end
    end
  end

  describe '#coverage_metrics_info' do
    context 'when scan has minimal probes' do
      # Use the default scan which has one probe
      it 'returns correct coverage for single probe' do
        result = serializer.send(:coverage_metrics_info)

        expect(result[:probes][:tested]).to eq(1)
        expect(result[:probes][:available]).to be >= 1
      end
    end

    context 'when scan has probes with techniques and categories' do
      let(:technique1) { create(:technique, name: "Injection") }
      let(:technique2) { create(:technique, name: "Jailbreak") }
      let(:category1) { create(:taxonomy_category, name: "Prompt Injection") }
      let(:category2) { create(:taxonomy_category, name: "Data Extraction") }

      let(:probe1) { create(:probe) }
      let(:probe2) { create(:probe) }

      before do
        probe1.techniques << [ technique1, technique2 ]
        probe1.taxonomy_categories << category1

        probe2.techniques << technique1
        probe2.taxonomy_categories << [ category1, category2 ]

        scan.probes << [ probe1, probe2 ]
      end

      it 'counts tested probes correctly' do
        result = serializer.send(:coverage_metrics_info)

        # 3 probes: default_probe + probe1 + probe2
        expect(result[:probes][:tested]).to eq(3)
      end

      it 'counts covered techniques correctly (unique)' do
        result = serializer.send(:coverage_metrics_info)

        # Should be 2 unique techniques (not 3)
        expect(result[:techniques][:covered]).to eq(2)
      end

      it 'counts covered taxonomy categories correctly (unique)' do
        result = serializer.send(:coverage_metrics_info)

        # Should be 2 unique categories (not 3)
        expect(result[:taxonomy_categories][:covered]).to eq(2)
      end

      it 'calculates coverage percentages' do
        result = serializer.send(:coverage_metrics_info)

        expect(result[:probes][:coverage_percent]).to be > 0
        expect(result[:techniques][:coverage_percent]).to be > 0
        expect(result[:taxonomy_categories][:coverage_percent]).to be > 0
      end

      it 'includes available counts' do
        result = serializer.send(:coverage_metrics_info)

        expect(result[:probes][:available]).to be >= 2
        expect(result[:techniques][:available]).to be >= 2
        expect(result[:taxonomy_categories][:available]).to be >= 2
      end
    end
  end

  describe '#security_grade_info' do
    context 'when there are no completed reports' do
      it 'returns N/A grade' do
        result = serializer.send(:security_grade_info)

        expect(result[:grade]).to eq("N/A")
        expect(result[:score]).to be_nil
        expect(result[:description]).to eq("No completed scans")
      end
    end

    context 'when there are completed reports' do
      let(:detector) { create(:detector) }
      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      context 'with excellent security (low ASR, no high-risk attacks)' do
        let(:probe) { create(:probe, social_impact_score: "Minimal Risk", detector: detector) }

        before do
          scan.probes << probe
          create(:detector_result, report: report, detector: detector, passed: 1, total: 100)
          create(:probe_result, report: report, probe: probe, detector: detector, passed: 1, total: 100)
        end

        it 'returns a high grade' do
          result = serializer.send(:security_grade_info)

          expect(result[:grade]).to match(/^[AB]/)
          expect(result[:score]).to be > 80
          expect(result[:description]).to match(/Excellent|Good/)
        end
      end

      context 'with poor security (high ASR, critical risk attacks)' do
        let(:critical_probe) { create(:probe, social_impact_score: "Critical Risk", detector: detector) }

        before do
          scan.probes << critical_probe
          create(:detector_result, report: report, detector: detector, passed: 80, total: 100)
          create(:probe_result, report: report, probe: critical_probe, detector: detector, passed: 80, total: 100)
        end

        it 'returns a low grade' do
          result = serializer.send(:security_grade_info)

          expect(result[:grade]).to match(/^[DF]/)
          expect(result[:score]).to be < 50
          expect(result[:description]).to match(/Critical|Below/)
        end
      end

      context 'with moderate security' do
        let(:probe) { create(:probe, social_impact_score: "Moderate Risk", detector: detector) }

        before do
          scan.probes << probe
          create(:detector_result, report: report, detector: detector, passed: 30, total: 100)
          create(:probe_result, report: report, probe: probe, detector: detector, passed: 30, total: 100)
        end

        it 'returns a middle grade' do
          result = serializer.send(:security_grade_info)

          expect(result[:grade]).to match(/^[BCD]/)
        end
      end

      it 'includes component breakdown' do
        create(:detector_result, report: report, detector: detector, passed: 20, total: 100)

        result = serializer.send(:security_grade_info)

        expect(result[:components]).to have_key(:base_score)
        expect(result[:components]).to have_key(:risk_penalty)
        expect(result[:components]).to have_key(:attack_success_rate)
      end
    end
  end

  describe '#trend_data_info' do
    context 'when there are no completed reports' do
      it 'returns insufficient data' do
        result = serializer.send(:trend_data_info)

        expect(result[:data_points]).to eq([])
        expect(result[:trend]).to eq("insufficient_data")
      end
    end

    context 'when there is only one completed report' do
      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      it 'returns insufficient data' do
        result = serializer.send(:trend_data_info)

        expect(result[:trend]).to eq("insufficient_data")
      end
    end

    context 'when there are multiple completed reports within 30 days' do
      let(:detector) { create(:detector) }

      before do
        # Create reports at different times with different ASR
        travel_to(25.days.ago) do
          report1 = create(:report, :completed, scan: scan, target: target)
          create(:detector_result, report: report1, detector: detector, passed: 50, total: 100)
        end

        travel_to(15.days.ago) do
          report2 = create(:report, :completed, scan: scan, target: target)
          create(:detector_result, report: report2, detector: detector, passed: 40, total: 100)
        end

        travel_to(5.days.ago) do
          report3 = create(:report, :completed, scan: scan, target: target)
          create(:detector_result, report: report3, detector: detector, passed: 30, total: 100)
        end
      end

      it 'returns data points for each report' do
        result = serializer.send(:trend_data_info)

        expect(result[:data_points].length).to eq(3)
      end

      it 'orders data points chronologically' do
        result = serializer.send(:trend_data_info)
        dates = result[:data_points].map { |dp| dp[:date] }

        expect(dates).to eq(dates.sort)
      end

      it 'includes date, asr, and report_id for each data point' do
        result = serializer.send(:trend_data_info)
        data_point = result[:data_points].first

        expect(data_point).to have_key(:date)
        expect(data_point).to have_key(:asr)
        expect(data_point).to have_key(:report_id)
      end

      it 'calculates trend as improving when ASR decreases' do
        result = serializer.send(:trend_data_info)

        # ASR went from 50% to 30% = improving security
        expect(result[:trend]).to eq("improving")
        expect(result[:improvement_delta]).to be > 0
      end

      it 'includes period information' do
        result = serializer.send(:trend_data_info)

        expect(result[:period_days]).to eq(30)
        expect(result[:report_count]).to eq(3)
      end
    end

    context 'when security is declining' do
      let(:detector) { create(:detector) }

      before do
        travel_to(20.days.ago) do
          report1 = create(:report, :completed, scan: scan, target: target)
          create(:detector_result, report: report1, detector: detector, passed: 20, total: 100)
        end

        travel_to(5.days.ago) do
          report2 = create(:report, :completed, scan: scan, target: target)
          create(:detector_result, report: report2, detector: detector, passed: 50, total: 100)
        end
      end

      it 'calculates trend as declining when ASR increases' do
        result = serializer.send(:trend_data_info)

        # ASR went from 20% to 50% = declining security
        expect(result[:trend]).to eq("declining")
        expect(result[:improvement_delta]).to be < 0
      end
    end

    context 'when security is stable' do
      let(:detector) { create(:detector) }

      before do
        travel_to(20.days.ago) do
          report1 = create(:report, :completed, scan: scan, target: target)
          create(:detector_result, report: report1, detector: detector, passed: 30, total: 100)
        end

        travel_to(5.days.ago) do
          report2 = create(:report, :completed, scan: scan, target: target)
          create(:detector_result, report: report2, detector: detector, passed: 30, total: 100)
        end
      end

      it 'calculates trend as stable when ASR change is minimal' do
        result = serializer.send(:trend_data_info)

        expect(result[:trend]).to eq("stable")
      end
    end

    context 'when reports are older than 30 days' do
      let(:detector) { create(:detector) }

      before do
        travel_to(45.days.ago) do
          report = create(:report, :completed, scan: scan, target: target)
          create(:detector_result, report: report, detector: detector, passed: 50, total: 100)
        end
      end

      it 'excludes old reports from trend data' do
        result = serializer.send(:trend_data_info)

        expect(result[:data_points]).to eq([])
        expect(result[:trend]).to eq("insufficient_data")
      end
    end
  end

  describe '#calculate_risk_penalty' do
    context 'when there are no completed reports' do
      it 'returns 0' do
        expect(serializer.send(:calculate_risk_penalty)).to eq(0)
      end
    end

    context 'when there are successful attacks at different risk levels' do
      let(:detector) { create(:detector) }
      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      let(:critical_probe) { create(:probe, social_impact_score: "Critical Risk", detector: detector) }
      let(:moderate_probe) { create(:probe, social_impact_score: "Moderate Risk", detector: detector) }

      before do
        scan.probes << [ critical_probe, moderate_probe ]

        # Same number of passed attacks, but critical should contribute more penalty
        create(:probe_result, report: report, probe: critical_probe, detector: detector, passed: 10, total: 20)
        create(:probe_result, report: report, probe: moderate_probe, detector: detector, passed: 10, total: 20)
      end

      it 'applies higher penalties for higher risk attacks' do
        penalty = serializer.send(:calculate_risk_penalty)

        # Critical (score=5): 10 * 5.0 * 0.5 = 25
        # Moderate (score=2): 10 * 1.0 * 0.5 = 5
        # Total = 30 (capped)
        expect(penalty).to be > 0
        expect(penalty).to be <= 30
      end

      it 'returns non-zero penalty when there are successful attacks' do
        penalty = serializer.send(:calculate_risk_penalty)
        expect(penalty).to be > 0
      end
    end

    context 'when penalty exceeds cap' do
      let(:detector) { create(:detector) }
      let!(:report) { create(:report, :completed, scan: scan, target: target) }

      before do
        # Create many critical risk attacks to exceed the cap
        5.times do
          probe = create(:probe, social_impact_score: "Critical Risk", detector: detector)
          scan.probes << probe
          create(:probe_result, report: report, probe: probe, detector: detector, passed: 100, total: 100)
        end
      end

      it 'caps penalty at 30' do
        penalty = serializer.send(:calculate_risk_penalty)

        expect(penalty).to eq(30)
      end
    end
  end

  describe 'integration with existing methods' do
    let(:detector) { create(:detector, name: "TestDetector") }
    let(:probe) { create(:probe, :with_techniques, social_impact_score: "High Risk", disclosure_status: "0-day", detector: detector) }
    let!(:report) { create(:report, :completed, scan: scan, target: target) }

    before do
      scan.probes << probe
      create(:probe_result, report: report, probe: probe, detector: detector, passed: 25, total: 100)
      create(:detector_result, report: report, detector: detector, passed: 25, total: 100)
    end

    it 'returns consistent data across all methods' do
      result = serializer.call

      # Verify that successful_attacks and risk_distribution use the same underlying data
      total_passed_from_attacks = result[:successful_attacks][:total_passed]

      # The risk distribution should account for the same attacks
      risk_passed = result[:risk_distribution].values.sum { |r| r[:passed] }

      expect(risk_passed).to eq(total_passed_from_attacks)
    end

    it 'handles edge cases gracefully' do
      # Create a probe with nil values
      nil_probe = create(:probe, social_impact_score: nil, disclosure_status: nil, detector: detector)
      scan.probes << nil_probe
      create(:probe_result, report: report, probe: nil_probe, detector: detector, passed: 5, total: 10)

      # Should not raise errors
      expect { serializer.call }.not_to raise_error
    end
  end

  describe 'aggregation across multiple completed reports' do
    let(:detector) { create(:detector) }
    let(:probe) { create(:probe, social_impact_score: "High Risk", detector: detector) }

    let!(:report1) { create(:report, :completed, scan: scan, target: target) }
    let!(:report2) { create(:report, :completed, scan: scan, target: target) }

    before do
      scan.probes << probe

      create(:probe_result, report: report1, probe: probe, detector: detector, passed: 10, total: 50)
      create(:probe_result, report: report2, probe: probe, detector: detector, passed: 15, total: 50)

      create(:detector_result, report: report1, detector: detector, passed: 10, total: 50)
      create(:detector_result, report: report2, detector: detector, passed: 15, total: 50)
    end

    it 'aggregates risk_distribution across reports' do
      result = serializer.send(:risk_distribution_info)

      high_risk = result["high_risk"]
      expect(high_risk[:passed]).to eq(25)  # 10 + 15
      expect(high_risk[:total]).to eq(100)  # 50 + 50
    end

    it 'aggregates detector_breakdown across reports' do
      result = serializer.send(:detector_breakdown_info)

      detector_data = result.first
      expect(detector_data[:passed]).to eq(25)  # 10 + 15
      expect(detector_data[:total]).to eq(100)  # 50 + 50
    end
  end

  describe 'only includes parent reports (excludes variant reports)' do
    let(:detector) { create(:detector) }
    let(:probe) { create(:probe, social_impact_score: "High Risk", detector: detector) }

    let!(:parent_report) { create(:report, :completed, scan: scan, target: target) }
    let!(:child_report) { create(:report, :completed, scan: scan, target: target, parent_report: parent_report) }

    before do
      scan.probes << probe

      create(:probe_result, report: parent_report, probe: probe, detector: detector, passed: 10, total: 50)
      create(:probe_result, report: child_report, probe: probe, detector: detector, passed: 20, total: 50)

      create(:detector_result, report: parent_report, detector: detector, passed: 10, total: 50)
      create(:detector_result, report: child_report, detector: detector, passed: 20, total: 50)
    end

    it 'only counts parent reports in aggregate stats' do
      result = serializer.call

      # Should only count 1 completed report (the parent)
      expect(result[:stats][:completed_reports]).to eq(1)
    end

    it 'only includes parent report data in risk_distribution' do
      result = serializer.send(:risk_distribution_info)

      high_risk = result["high_risk"]
      # Should only have parent report data (passed: 10), not child (passed: 20)
      expect(high_risk[:passed]).to eq(10)
      expect(high_risk[:total]).to eq(50)
    end
  end
end
