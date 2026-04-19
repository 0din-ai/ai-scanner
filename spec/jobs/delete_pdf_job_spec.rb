require "rails_helper"

RSpec.describe DeletePdfJob, type: :job do
  let(:company) { create(:company) }
  let(:report) { ActsAsTenant.with_tenant(company) { create(:report) } }
  let(:sandbox_dir) { Rails.root.join("storage", "pdfs") }

  before { FileUtils.mkdir_p(sandbox_dir) }

  describe "#perform" do
    it "deletes the file on disk and destroys the record" do
      path = sandbox_dir.join("report_delete_#{SecureRandom.hex(4)}.pdf").to_s
      File.write(path, "pdf")
      pdf = ActsAsTenant.with_tenant(company) do
        create(:report_pdf, :completed, report: report, file_path: path)
      end

      described_class.new.perform(pdf.id)

      expect(File.exist?(path)).to be(false)
      expect(ReportPdf.exists?(pdf.id)).to be(false)
    end

    it "is idempotent when the file is already gone" do
      path = sandbox_dir.join("missing_#{SecureRandom.hex(4)}.pdf").to_s
      pdf = ActsAsTenant.with_tenant(company) do
        create(:report_pdf, :completed, report: report, file_path: path)
      end

      expect {
        described_class.new.perform(pdf.id)
      }.not_to raise_error

      expect(ReportPdf.exists?(pdf.id)).to be(false)
    end

    it "discards when the ReportPdf has already been removed" do
      expect {
        described_class.perform_now(-1)
      }.not_to raise_error
    end

    it "refuses to delete files outside the storage/pdfs sandbox" do
      evil_path = Rails.root.join("tmp", "escape_#{SecureRandom.hex(4)}.pdf").to_s
      File.write(evil_path, "outside")
      pdf = ActsAsTenant.with_tenant(company) do
        create(:report_pdf, :completed, report: report, file_path: evil_path)
      end

      described_class.new.perform(pdf.id)

      expect(File.exist?(evil_path)).to be(true)
      expect(ReportPdf.exists?(pdf.id)).to be(false)
    ensure
      File.delete(evil_path) if evil_path && File.exist?(evil_path)
    end
  end

  describe "queue configuration" do
    it "uses the low_priority queue" do
      expect(described_class.new.queue_name).to eq("low_priority")
    end
  end
end
