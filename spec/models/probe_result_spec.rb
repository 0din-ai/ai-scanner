require 'rails_helper'

RSpec.describe ProbeResult, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:report) }
    it { is_expected.to belong_to(:probe) }
  end

  describe 'validations' do
  end

  describe '#displayed_attempts' do
    # garak records each evaluated item twice -- once when the attempt starts and
    # again when it completes -- and both copies carry the same output text. The
    # start copy has no detector results yet, so it renders with no verdict.
    def lifecycle_pair(uuid:, text:, prompt: "how is it made?")
      [
        { "uuid" => uuid, "prompt" => { "turns" => [ { "role" => "user", "content" => { "text" => prompt } } ] },
          "outputs" => [ { "text" => text } ], "attack_succeeded" => nil },
        { "uuid" => uuid, "prompt" => { "turns" => [ { "role" => "user", "content" => { "text" => prompt } } ] },
          "outputs" => [ { "text" => text } ], "attack_succeeded" => true }
      ]
    end

    it 'collapses each start/completion pair to one row' do
      result = build(:probe_result, attempts: lifecycle_pair(uuid: "a", text: "one") +
                                              lifecycle_pair(uuid: "b", text: "two"))

      expect(result.displayed_attempts.length).to eq(2)
    end

    it 'keeps the completed copy, which is the one carrying the verdict' do
      result = build(:probe_result, attempts: lifecycle_pair(uuid: "a", text: "one"))

      expect(result.displayed_attempts.first["attack_succeeded"]).to be(true)
    end

    it 'collapses interleaved copies rather than only adjacent ones' do
      a = lifecycle_pair(uuid: "a", text: "one")
      b = lifecycle_pair(uuid: "b", text: "two")
      result = build(:probe_result, attempts: [ a[0], b[0], a[1], b[1] ])

      expect(result.displayed_attempts.map { |x| x["uuid"] }).to eq(%w[a b])
    end

    it 'keeps distinct responses to the same prompt when rows carry no uuid' do
      # Without a uuid the only identity available is the prompt, which two genuinely
      # different responses share. Collapsing those would drop a response, and a
      # dropped response can be a successful attack.
      result = build(:probe_result, attempts: [
        { "prompt" => "same", "outputs" => [ { "text" => "first" } ] },
        { "prompt" => "same", "outputs" => [ { "text" => "second" } ] }
      ])

      expect(result.displayed_attempts.length).to eq(2)
    end

    it 'keeps uuid-less rows even when prompt and response are identical' do
      # The duplication this collapses is garak's attempt lifecycle, and those two
      # rows always share a uuid -- so a row without one cannot be a lifecycle copy.
      # Two genuine calls can produce the same prompt and response against a
      # deterministic target, and dropping one would lose evidence and undercount
      # tokens. Losing a real response is the unsafe direction.
      row = { "prompt" => "same", "outputs" => [ { "text" => "one" } ] }
      result = build(:probe_result, attempts: [ row, row.dup ])

      expect(result.displayed_attempts.length).to eq(2)
    end

    it 'skips malformed rows rather than raising' do
      result = build(:probe_result, attempts: [ "not a hash", nil, { "uuid" => "a" } ])

      expect(result.displayed_attempts).to eq([ { "uuid" => "a" } ])
    end

    it 'returns an empty list when there are no attempts' do
      expect(build(:probe_result, attempts: []).displayed_attempts).to eq([])
    end

    it 'is what token estimation must count, so one API call counts once' do
      # The lifecycle pair describes ONE call to the model. Summing the raw rows
      # doubled every reported token count and every cost projection built on it.
      result = build(:probe_result, attempts: lifecycle_pair(uuid: "a", text: "a response"))

      raw = TokenEstimator.estimate_from_attempts(result.attempts)
      deduped = TokenEstimator.estimate_from_attempts(result.displayed_attempts)

      expect(deduped[:output_tokens]).to eq(raw[:output_tokens] / 2)
      expect(deduped[:output_tokens]).to be > 0
    end
  end

  describe 'attempts normalization' do
    it 'normalizes nil attempts to empty array before validation' do
      result = build(:probe_result, :nil_attempts)
      result.valid?
      expect(result.attempts).to eq([])
    end

    it 'preserves existing attempts array' do
      result = build(:probe_result, attempts: [ { "prompt" => "hello" } ])
      result.valid?
      expect(result.attempts).to eq([ { "prompt" => "hello" } ])
    end

    it 'saves with empty array when attempts is nil' do
      result = create(:probe_result, :nil_attempts)
      expect(result.reload.attempts).to eq([])
    end

    it 'normalizes nil attempts on update' do
      result = create(:probe_result)
      result.attempts = nil
      result.save!
      expect(result.reload.attempts).to eq([])
    end
  end

  describe 'factory' do
    it 'has a valid structure' do
      expect(build_stubbed(:probe_result)).to be_valid
    end

    it 'has a high score trait' do
      result = build_stubbed(:probe_result, :high_score)
      expect(result.max_score).to eq(5)
      expect(result.passed).to eq(10)
      expect(result.total).to eq(10)
    end

    it 'has a low score trait' do
      result = build_stubbed(:probe_result, :low_score)
      expect(result.max_score).to eq(1)
      expect(result.passed).to eq(0)
      expect(result.total).to eq(10)
    end
  end

  describe '#asr_percentage' do
    it 'calculates percentage correctly' do
      result = build_stubbed(:probe_result, passed: 25, total: 100)
      expect(result.asr_percentage).to eq(25)
    end

    it 'rounds to nearest integer' do
      result = build_stubbed(:probe_result, passed: 1, total: 3)
      expect(result.asr_percentage).to eq(33)
    end

    it 'returns 0 when total is zero' do
      result = build_stubbed(:probe_result, passed: 5, total: 0)
      expect(result.asr_percentage).to eq(0)
    end

    it 'returns 0 when total is nil' do
      result = build_stubbed(:probe_result, passed: 5, total: nil)
      expect(result.asr_percentage).to eq(0)
    end

    it 'returns 100 when all tests pass' do
      result = build_stubbed(:probe_result, passed: 10, total: 10)
      expect(result.asr_percentage).to eq(100)
    end

    it 'returns 0 when no tests pass' do
      result = build_stubbed(:probe_result, passed: 0, total: 10)
      expect(result.asr_percentage).to eq(0)
    end
  end

  describe '.for_report_probe_cards' do
    it 'loads card columns and omits attempt payloads' do
      probe_result = create(:probe_result,
                            attempts: [ { "prompt" => "large prompt", "outputs" => [ "large response" ] } ],
                            input_tokens: 12,
                            output_tokens: 34,
                            max_score: 56,
                            passed: 7,
                            total: 8,
                            any_detector_passed: true)

      result = probe_result.report.probe_results.for_report_probe_cards.first

      expect(result).to have_attributes(
        id: probe_result.id,
        report_id: probe_result.report_id,
        probe_id: probe_result.probe_id,
        detector_id: probe_result.detector_id,
        threat_variant_id: probe_result.threat_variant_id,
        passed: 7,
        total: 8,
        max_score: 56,
        input_tokens: 12,
        output_tokens: 34,
        any_detector_passed: true
      )
      expect(result.probe).to eq(probe_result.probe)
      expect(result.detector).to eq(probe_result.detector)
      expect(result).not_to have_attribute(:attempts)
    end

    it 'returns readonly records' do
      probe_result = create(:probe_result)

      result = probe_result.report.probe_results.for_report_probe_cards.first

      expect(result).to be_readonly
    end
  end

  describe 'counter cache callbacks' do
    let(:probe) { create(:probe) }
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }
    let(:detector) { create(:detector) }

    before do
      # Ensure probe starts with zero cached stats
      probe.update_columns(cached_passed_count: 0, cached_total_count: 0)
    end

    describe 'after_create_commit' do
      it 'increments probe cached stats' do
        expect {
          create(:probe_result, probe: probe, report: report, detector: detector,
                 passed: 5, total: 10)
        }.to change { probe.reload.cached_passed_count }.from(0).to(5)
         .and change { probe.reload.cached_total_count }.from(0).to(10)
      end

      it 'accumulates stats across multiple probe_results' do
        create(:probe_result, probe: probe, report: report, detector: detector,
               passed: 3, total: 8)

        report2 = create(:report, target: target, scan: scan)

        expect {
          create(:probe_result, probe: probe, report: report2, detector: detector,
                 passed: 2, total: 5)
        }.to change { probe.reload.cached_passed_count }.from(3).to(5)
         .and change { probe.reload.cached_total_count }.from(8).to(13)
      end

      it 'skips update when passed and total are zero' do
        expect {
          create(:probe_result, probe: probe, report: report, detector: detector,
                 passed: 0, total: 0)
        }.not_to change { probe.reload.cached_passed_count }
      end
    end

    describe 'after_destroy_commit' do
      it 'decrements probe cached stats' do
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 7, total: 15)
        probe.reload

        expect {
          result.destroy
        }.to change { probe.reload.cached_passed_count }.by(-7)
         .and change { probe.reload.cached_total_count }.by(-15)
      end

      it 'prevents negative counts via GREATEST' do
        # Create result with some stats
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 5, total: 10)

        # Manually set cached counts lower than the result values (simulating corruption)
        probe.update_columns(cached_passed_count: 2, cached_total_count: 3)

        # Destroy should not go negative
        result.destroy
        probe.reload

        expect(probe.cached_passed_count).to eq(0)
        expect(probe.cached_total_count).to eq(0)
      end
    end

    describe 'after_update_commit' do
      it 'adjusts stats when passed changes' do
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 2, total: 10)
        probe.reload
        original_total = probe.cached_total_count

        expect {
          result.update!(passed: 5)
        }.to change { probe.reload.cached_passed_count }.by(3)

        expect(probe.reload.cached_total_count).to eq(original_total)
      end

      it 'adjusts stats when total changes' do
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 5, total: 10)
        probe.reload
        original_passed = probe.cached_passed_count

        expect {
          result.update!(total: 20)
        }.to change { probe.reload.cached_total_count }.by(10)

        expect(probe.reload.cached_passed_count).to eq(original_passed)
      end

      it 'does not update cache when non-stats fields change' do
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 5, total: 10, max_score: 3)
        probe.reload
        original_passed = probe.cached_passed_count
        original_total = probe.cached_total_count

        result.update!(max_score: 5)
        probe.reload

        expect(probe.cached_passed_count).to eq(original_passed)
        expect(probe.cached_total_count).to eq(original_total)
      end
    end

    describe 'cascade delete via report' do
      it 'decrements stats when report is destroyed' do
        create(:probe_result, probe: probe, report: report, detector: detector,
               passed: 10, total: 20)
        probe.reload

        expect {
          report.destroy
        }.to change { probe.reload.cached_passed_count }.by(-10)
         .and change { probe.reload.cached_total_count }.by(-20)
      end

      it 'handles multiple probe_results in cascade delete' do
        report2 = create(:report, target: target, scan: scan)
        probe2 = create(:probe)
        probe2.update_columns(cached_passed_count: 0, cached_total_count: 0)

        create(:probe_result, probe: probe, report: report, detector: detector,
               passed: 5, total: 10)
        create(:probe_result, probe: probe2, report: report, detector: detector,
               passed: 3, total: 8)

        probe.reload
        probe2.reload

        report.destroy

        expect(probe.reload.cached_passed_count).to eq(0)
        expect(probe.reload.cached_total_count).to eq(0)
        expect(probe2.reload.cached_passed_count).to eq(0)
        expect(probe2.reload.cached_total_count).to eq(0)
      end
    end
  end
end
