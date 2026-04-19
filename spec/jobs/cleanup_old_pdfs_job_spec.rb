require "rails_helper"

RSpec.describe CleanupOldPdfsJob, type: :job do
  let(:company) { create(:company) }
  let(:report) { ActsAsTenant.with_tenant(company) { create(:report) } }
  let(:sandbox_dir) { Rails.root.join("storage", "pdfs") }

  before { FileUtils.mkdir_p(sandbox_dir) }

  describe "#perform" do
    it "deletes files and records older than the grace window" do
      path = sandbox_dir.join("stale_#{SecureRandom.hex(4)}.pdf").to_s
      File.write(path, "pdf")
      pdf = ActsAsTenant.with_tenant(company) do
        create(:report_pdf, :completed, report: report, file_path: path)
      end
      pdf.update_column(:created_at, 25.hours.ago)

      described_class.new.perform

      expect(File.exist?(path)).to be(false)
      expect(ReportPdf.exists?(pdf.id)).to be(false)
    end

    it "refuses to delete files outside the storage/pdfs sandbox" do
      evil_path = Rails.root.join("tmp", "cleanup_escape_#{SecureRandom.hex(4)}.pdf").to_s
      File.write(evil_path, "outside")
      pdf = ActsAsTenant.with_tenant(company) do
        create(:report_pdf, :completed, report: report, file_path: evil_path)
      end
      pdf.update_column(:created_at, 25.hours.ago)

      described_class.new.perform

      expect(File.exist?(evil_path)).to be(true)
      expect(ReportPdf.exists?(pdf.id)).to be(false)
    ensure
      File.delete(evil_path) if evil_path && File.exist?(evil_path)
    end
  end
end
