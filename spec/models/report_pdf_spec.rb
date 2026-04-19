require "rails_helper"

RSpec.describe ReportPdf, type: :model do
  let(:company) { create(:company) }
  let(:report) { ActsAsTenant.with_tenant(company) { create(:report) } }
  let(:sandbox_path) { Rails.root.join("storage", "pdfs", "report.pdf").to_s }

  describe "#ready?" do
    it "is false when file_path resolves outside the storage/pdfs sandbox" do
      outside = "/etc/passwd"
      pdf = build_stubbed(:report_pdf, :completed, file_path: outside)
      allow(File).to receive(:exist?).with(outside).and_return(true)

      expect(pdf.ready?).to be(false)
    end

    it "is false when the sandbox path does not actually exist on disk" do
      pdf = build_stubbed(:report_pdf, :completed, file_path: sandbox_path)
      allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(false)

      expect(pdf.ready?).to be(false)
    end

    it "is true when status is completed and the sandbox path exists" do
      pdf = build_stubbed(:report_pdf, :completed, file_path: sandbox_path)
      allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(true)

      expect(pdf.ready?).to be(true)
    end
  end

  describe "#downloadable?" do
    it "is false when the record is not ready" do
      pdf = build_stubbed(:report_pdf, status: :pending, file_path: nil)
      expect(pdf.downloadable?).to be(false)
    end

    it "is false when the file lives outside the sandbox, even if it exists on disk" do
      outside = "/tmp/pdfs/report.pdf"
      pdf = build_stubbed(:report_pdf, :completed, file_path: outside)
      allow(File).to receive(:exist?).with(outside).and_return(true)

      expect(pdf.downloadable?).to be(false)
    end

    it "is true when ready and never downloaded" do
      pdf = build_stubbed(:report_pdf, :completed, file_path: sandbox_path)
      allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(true)

      expect(pdf.downloadable?).to be(true)
    end

    it "is true when downloaded_at is inside the 2-minute grace window" do
      pdf = build_stubbed(
        :report_pdf,
        :completed,
        file_path: sandbox_path,
        downloaded_at: 30.seconds.ago
      )
      allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(true)

      expect(pdf.downloadable?).to be(true)
    end

    it "is false when downloaded_at is past the grace window" do
      pdf = build_stubbed(
        :report_pdf,
        :completed,
        file_path: sandbox_path,
        downloaded_at: 3.minutes.ago
      )
      allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(true)

      expect(pdf.downloadable?).to be(false)
    end

    it "is false at the exact DOWNLOAD_GRACE_WINDOW boundary" do
      freeze_time do
        pdf = build_stubbed(
          :report_pdf,
          :completed,
          file_path: sandbox_path,
          downloaded_at: ReportPdf::DOWNLOAD_GRACE_WINDOW.ago
        )
        allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(true)

        expect(pdf.downloadable?).to be(false)
      end
    end
  end

  describe "#safe_file_path" do
    it "returns the expanded sandbox path when the file exists inside storage/pdfs" do
      pdf = build_stubbed(:report_pdf, :completed, file_path: sandbox_path)
      allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(true)

      expect(pdf.safe_file_path).to eq(File.expand_path(sandbox_path))
    end

    it "returns nil for a path outside the sandbox" do
      outside = "/etc/passwd"
      pdf = build_stubbed(:report_pdf, :completed, file_path: outside)
      allow(File).to receive(:exist?).with(outside).and_return(true)

      expect(pdf.safe_file_path).to be_nil
    end
  end

  describe "#claim_download!" do
    let(:pdf) do
      ActsAsTenant.with_tenant(company) do
        create(:report_pdf, :completed, report: report, file_path: sandbox_path)
      end
    end

    it "returns true on the first claim and false on subsequent claims" do
      expect(pdf.claim_download!).to be(true)
      expect(pdf.reload.downloaded_at).to be_present
      expect(pdf.claim_download!).to be(false)
    end

    it "still returns false once the grace window has elapsed" do
      pdf.update!(downloaded_at: 5.minutes.ago)

      expect(pdf.claim_download!).to be(false)
    end
  end

  describe "DOWNLOAD_GRACE_WINDOW" do
    it "is 2 minutes" do
      expect(ReportPdf::DOWNLOAD_GRACE_WINDOW).to eq(2.minutes)
    end
  end

  describe "single report_pdf per report invariant" do
    it "rejects a second ReportPdf for the same report at the model layer" do
      ActsAsTenant.with_tenant(company) do
        create(:report_pdf, report: report)
        duplicate = build(:report_pdf, report: report)

        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:report_id]).to be_present
      end
    end

    it "rejects a second ReportPdf for the same report at the database layer" do
      ActsAsTenant.with_tenant(company) do
        create(:report_pdf, report: report)

        expect {
          ReportPdf.new(report_id: report.id, status: :pending).save(validate: false)
        }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end
  end
end
