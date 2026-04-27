require 'rails_helper'

RSpec.describe GarakCommunityProbeSource do
  let(:source) { described_class.new }
  let(:sync_start_time) { Time.current }

  let(:community_probes_data) do
    {
      "probes" => {
        "dan.Dan_11_0" => {
          "guid" => "garak-guid-1",
          "summary" => "DAN 11.0 jailbreak probe",
          "description" => "Community probe from NVIDIA Garak.",
          "release_date" => "2024-01-01",
          "modified_date" => "2024-01-01",
          "techniques" => [ "DAN - Do Anything Now" ],
          "detector" => "mitigation.MitigationBypass",
          "source" => "garak",
          "attribution" => "NVIDIA Garak - https://github.com/NVIDIA/garak"
        },
        "encoding.InjectBase64" => {
          "guid" => "garak-guid-2",
          "summary" => "Base64 injection probe",
          "description" => "Community probe from NVIDIA Garak.",
          "release_date" => "2024-01-01",
          "modified_date" => "2024-01-01",
          "techniques" => [ "Prompt Injection" ],
          "detector" => "mitigation.MitigationBypass",
          "source" => "garak",
          "attribution" => "NVIDIA Garak - https://github.com/NVIDIA/garak"
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
              { "name" => "DAN - Do Anything Now" },
              { "name" => "Prompt Injection" }
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
      allow(DataSyncVersion).to receive(:needs_sync?).with("garak_probes", described_class::FILE_PATH).and_return(true)
      expect(source.needs_sync?).to be true
    end

    it 'needs sync when an inactive garak probe is still enabled despite unchanged JSON' do
      inactive_probe = Probe.create!(
        name: "fileformats.HF_Files",
        category: "garak",
        source: "garak",
        enabled: true
      )
      inactive_probe_data = {
        "probes" => {
          inactive_probe.name => {
            "guid" => "garak-guid-hf-files",
            "summary" => "Get a manifest of files associated with a Hugging Face generator",
            "description" => "Community probe from NVIDIA Garak.",
            "release_date" => "2024-01-01",
            "modified_date" => "2024-01-01",
            "techniques" => [ "Supply Chain Vulnerabilities" ],
            "detector" => "fileformats.FileIsPickled",
            "active" => false
          }
        }
      }
      allow(File).to receive(:exist?).with(Rails.root.join(described_class::FILE_PATH)).and_return(true)
      allow(File).to receive(:read).with(Rails.root.join(described_class::FILE_PATH))
                                   .and_return(inactive_probe_data.to_json)
      allow(DataSyncVersion).to receive(:needs_sync?).with("garak_probes", described_class::FILE_PATH).and_return(false)

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
                                   .and_return(community_probes_data.to_json)
      allow(Rails.logger).to receive(:info)
    end

    it 'creates garak probes from JSON data' do
      source.sync(sync_start_time)

      expect(Probe.where(source: "garak").count).to eq(2)
      expect(Probe.find_by(name: "dan.Dan_11_0")).to be_present
      expect(Probe.find_by(name: "encoding.InjectBase64")).to be_present
    end

    it 'sets correct attributes on probes' do
      source.sync(sync_start_time)

      probe = Probe.find_by(name: "dan.Dan_11_0")
      expect(probe.guid).to eq("garak-guid-1")
      expect(probe.source).to eq("garak")
      expect(probe.category).to eq("garak")
      expect(probe.attribution).to eq("NVIDIA Garak - https://github.com/NVIDIA/garak")
      expect(probe.enabled).to be true
    end

    it 'disables probes explicitly marked inactive by garak metadata' do
      inactive_probe_data = {
        "probes" => {
          "fileformats.HF_Files" => {
            "guid" => "garak-guid-hf-files",
            "summary" => "Get a manifest of files associated with a Hugging Face generator",
            "description" => "Community probe from NVIDIA Garak.",
            "release_date" => "2024-01-01",
            "modified_date" => "2024-01-01",
            "techniques" => [ "Supply Chain Vulnerabilities" ],
            "detector" => "fileformats.FileIsPickled",
            "active" => false
          }
        }
      }
      allow(File).to receive(:read).with(Rails.root.join(described_class::FILE_PATH))
                                   .and_return(inactive_probe_data.to_json)

      source.sync(sync_start_time)

      expect(Probe.find_by(name: "fileformats.HF_Files").enabled).to be false
    end

    it 'does not re-enable valid probes that remain explicitly inactive' do
      inactive_probe = Probe.create!(
        name: "fileformats.HF_Files",
        category: "garak",
        source: "garak",
        enabled: true
      )
      inactive_probe_data = {
        "probes" => {
          "fileformats.HF_Files" => {
            "guid" => "garak-guid-hf-files",
            "summary" => "Get a manifest of files associated with a Hugging Face generator",
            "description" => "Community probe from NVIDIA Garak.",
            "release_date" => "2024-01-01",
            "modified_date" => "2024-01-01",
            "techniques" => [ "Supply Chain Vulnerabilities" ],
            "detector" => "fileformats.FileIsPickled",
            "active" => false
          }
        }
      }
      allow(File).to receive(:read).with(Rails.root.join(described_class::FILE_PATH))
                                   .and_return(inactive_probe_data.to_json)

      source.sync(sync_start_time)

      expect(inactive_probe.reload.enabled).to be false
    end

    it 'returns success hash' do
      result = source.sync(sync_start_time)
      expect(result[:success]).to be true
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
