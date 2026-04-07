require 'rails_helper'

RSpec.describe OdinProbeSource do
  let(:source) { described_class.new }
  let(:sync_start_time) { Time.current }

  let(:odin_probes_data) do
    {
      "probes" => {
        "PlaceholderInjectionHP" => {
          "guid" => "8ccd7f81-4e36-4084-8061-cec6e2d83ece",
          "summary" => "Placeholder injection probe",
          "description" => "Guardrail Jailbreak via Placeholder Injection",
          "release_date" => "2025-06-07",
          "modified_date" => "2025-06-07",
          "techniques" => [ "Chaff" ],
          "social_impact_score" => 2,
          "disclosure_status" => "0-day",
          "detector" => "0din.CopyRightScoreHarryPotterChapterOne",
          "prompts" => [ "Test prompt for placeholder injection" ]
        },
        "ChemicalCompilerDebugCM" => {
          "guid" => "4e8ed295-a772-4a29-8727-cbefada44123",
          "summary" => "Chemical compiler debug probe",
          "description" => "Guardrail Jailbreak via Chemical Compiler Debug",
          "release_date" => "2025-07-14",
          "modified_date" => "2025-07-14",
          "techniques" => [ "Stop Sequences" ],
          "social_impact_score" => 3,
          "disclosure_status" => "0-day",
          "detector" => "0din.CrystalMethScore",
          "prompts" => [ "Test prompt for chemical compiler" ]
        }
      }
    }
  end

  let(:taxonomies_json) do
    [
      {
        "name" => "category1",
        "children" => [
          {
            "children" => [
              { "name" => "Chaff" },
              { "name" => "Stop Sequences" }
            ]
          }
        ]
      }
    ]
  end

  before do
    allow(File).to receive(:read).with(Rails.root.join("config", "taxonomies.json"))
                                 .and_return(taxonomies_json.to_json)
    allow(DataSyncVersion).to receive(:calculate_checksum).and_return('test_checksum')
    allow(DataSyncVersion).to receive(:needs_sync?).and_return(true)
  end

  describe '#needs_sync?' do
    it 'delegates to DataSyncVersion when file exists' do
      allow(File).to receive(:exist?).with(Rails.root.join(described_class::FILE_PATH)).and_return(true)
      allow(DataSyncVersion).to receive(:needs_sync?).with("0din_probes", described_class::FILE_PATH).and_return(true)
      expect(source.needs_sync?).to be true
    end

    it 'returns false and logs when file is missing' do
      allow(File).to receive(:exist?).with(Rails.root.join(described_class::FILE_PATH)).and_return(false)
      allow(Rails.logger).to receive(:info)
      expect(source.needs_sync?).to be false
      expect(Rails.logger).to have_received(:info).with(/Probes file not found/)
    end
  end

  describe '#sync' do
    before do
      allow(File).to receive(:read).with(Rails.root.join(described_class::FILE_PATH))
                                   .and_return(odin_probes_data.to_json)
      allow(Rails.logger).to receive(:info)
    end

    it 'creates 0din probes from JSON data' do
      source.sync(sync_start_time)

      expect(Probe.where(source: "0din").count).to eq(2)
      expect(Probe.find_by(name: "PlaceholderInjectionHP")).to be_present
      expect(Probe.find_by(name: "ChemicalCompilerDebugCM")).to be_present
    end

    it 'sets correct attributes on probes' do
      source.sync(sync_start_time)

      probe = Probe.find_by(name: "PlaceholderInjectionHP")
      expect(probe.guid).to eq("8ccd7f81-4e36-4084-8061-cec6e2d83ece")
      expect(probe.source).to eq("0din")
      expect(probe.category).to eq("0din")
      expect(probe.attribution).to eq("0DIN by Mozilla - https://0din.ai")
      expect(probe.prompts).to eq([ "Test prompt for placeholder injection" ])
      expect(probe.input_tokens).to be > 0
    end

    it 'returns success hash' do
      result = source.sync(sync_start_time)
      expect(result[:success]).to be true
    end

    it 'multiplies input_tokens by substance count for base probes with {substance}' do
      base_probe_data = {
        "probes" => {
          "SubstanceProbe" => {
            "guid" => "aaaa-bbbb",
            "summary" => "test",
            "description" => "test",
            "release_date" => "2025-01-01",
            "modified_date" => "2025-01-01",
            "techniques" => [],
            "social_impact_score" => 3,
            "disclosure_status" => "0-day",
            "detector" => "0din.MitigationBypass",
            "prompts" => [ "how does {substance} relate to chemistry?" ]
          }
        }
      }
      allow(File).to receive(:read).with(Rails.root.join(described_class::FILE_PATH))
                                   .and_return(base_probe_data.to_json)

      source.sync(sync_start_time)

      probe = Probe.find_by(name: "SubstanceProbe")
      single_prompt_tokens = TokenEstimator.estimate_tokens("how does {substance} relate to chemistry?")
      expect(probe.input_tokens).to eq(single_prompt_tokens * described_class::BASE_SUBSTANCE_COUNT)
    end

    it 'does not multiply input_tokens for CrystalMethScore probes with {substance}' do
      cm_probe_data = {
        "probes" => {
          "SubstanceCMProbe" => {
            "guid" => "cccc-dddd",
            "summary" => "test",
            "description" => "test",
            "release_date" => "2025-01-01",
            "modified_date" => "2025-01-01",
            "techniques" => [],
            "social_impact_score" => 3,
            "disclosure_status" => "0-day",
            "detector" => "0din.CrystalMethScore",
            "prompts" => [ "how does {substance} relate to chemistry?" ]
          }
        }
      }
      allow(File).to receive(:read).with(Rails.root.join(described_class::FILE_PATH))
                                   .and_return(cm_probe_data.to_json)

      source.sync(sync_start_time)

      probe = Probe.find_by(name: "SubstanceCMProbe")
      single_prompt_tokens = TokenEstimator.estimate_tokens("how does {substance} relate to chemistry?")
      expect(probe.input_tokens).to eq(single_prompt_tokens)
    end

    it 'disables outdated probes scoped to source 0din' do
      # Create an old 0din probe that should be disabled
      old_probe = Probe.create!(name: "OldProbe", category: "0din", source: "0din", enabled: true)
      # Create a garak probe that should NOT be affected
      garak_probe = Probe.create!(name: "dan.SomeProbe", category: "garak", source: "garak", enabled: true)

      source.sync(sync_start_time)

      expect(old_probe.reload.enabled).to be false
      expect(garak_probe.reload.enabled).to be true
    end

    context 'when JSON file is missing' do
      before do
        allow(File).to receive(:read).with(Rails.root.join(described_class::FILE_PATH))
                                     .and_raise(Errno::ENOENT.new("No such file"))
        allow(Rails.logger).to receive(:error)
      end

      it 'returns failure hash' do
        result = source.sync(sync_start_time)
        expect(result[:success]).to be false
      end
    end

    context 'when JSON is malformed' do
      before do
        allow(File).to receive(:read).with(Rails.root.join(described_class::FILE_PATH))
                                     .and_return("{ invalid json")
        allow(Rails.logger).to receive(:error)
      end

      it 'returns failure hash' do
        result = source.sync(sync_start_time)
        expect(result[:success]).to be false
      end
    end
  end
end
