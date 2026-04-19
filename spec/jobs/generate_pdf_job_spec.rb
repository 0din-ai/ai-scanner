# frozen_string_literal: true

require "rails_helper"

RSpec.describe GeneratePdfJob, type: :job do
  let(:company) { create(:company) }
  let(:user) { create(:user, company: company) }
  let(:report) { ActsAsTenant.with_tenant(company) { create(:report) } }
  let!(:report_pdf) do
    ActsAsTenant.with_tenant(company) { create(:report_pdf, report: report) }
  end
  let(:storage_dir) { Rails.root.join("tmp", "spec_pdf_job_#{SecureRandom.hex(4)}") }

  before do
    allow(Rails.root).to receive(:join).and_call_original
    allow(Rails.root).to receive(:join).with("storage", "pdfs").and_return(storage_dir)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow(MonitoringService).to receive(:active?).and_return(false)
  end

  after { FileUtils.rm_rf(storage_dir) }

  describe "MAX_ATTEMPTS" do
    it "is 3" do
      expect(described_class::MAX_ATTEMPTS).to eq(3)
    end
  end

  describe "#perform" do
    context "when the report has no pdf record" do
      before { report_pdf.destroy! }

      it "returns early without invoking the generator" do
        expect(Reports::PdfGenerator).not_to receive(:new)

        expect {
          described_class.new.perform(report.id, user.id)
        }.not_to raise_error
      end

      it "does not broadcast anything" do
        described_class.new.perform(report.id, user.id)

        expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to)
      end
    end

    context "when the report itself no longer exists" do
      it "discards without raising" do
        expect {
          described_class.perform_now(-1, user.id)
        }.not_to raise_error
      end
    end

    context "on success" do
      before do
        allow_any_instance_of(Reports::PdfGenerator).to receive(:generate).and_return("PDF-BYTES")
      end

      it "marks the report_pdf completed and writes the bytes to disk" do
        described_class.new.perform(report.id, user.id)

        reloaded = report_pdf.reload
        expect(reloaded.status_completed?).to be(true)
        expect(reloaded.file_path).to eq(storage_dir.join("report_#{report.id}.pdf").to_s)
        expect(File.read(reloaded.file_path)).to eq("PDF-BYTES")
      end

      it "broadcasts ready on the user+report scoped stream" do
        described_class.new.perform(report.id, user.id)

        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
          "pdf_notifications:user_#{user.id}:report_#{report.id}",
          hash_including(target: "pdf-status-#{report.id}")
        )
      end

      it "includes a signed download_url that PdfDownloadToken can verify" do
        captured = nil
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) do |_stream, **opts|
          captured = opts
        end

        described_class.new.perform(report.id, user.id)

        expect(captured).to be_present
        html = captured[:html]
        expect(html).to include("data-pdf-status='ready'")

        download_url = html[/data-download-url='([^']+)'/, 1]
        expect(download_url).to be_present

        token = Rack::Utils.parse_nested_query(URI(download_url).query)["pdf_token"]
        expect(token).to be_present
        expect(Reports::PdfDownloadToken.verify(token, report_pdf.reload)).to be(true)
      end
    end

    context "on a mid-retry failure" do
      before do
        allow_any_instance_of(Reports::PdfGenerator).to receive(:generate)
          .and_raise(StandardError, "boom")
      end

      it "leaves the record in :processing (retry_on re-enqueues instead of marking failed)" do
        job = described_class.new(report.id, user.id)

        job.perform_now

        expect(report_pdf.reload.status_processing?).to be(true)
      end

      it "does not emit a failed broadcast" do
        job = described_class.new(report.id, user.id)

        job.perform_now

        expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to).with(
          anything,
          hash_including(html: a_string_matching(/data-pdf-status='failed'/))
        )
      end

      it "re-enqueues the job for another attempt" do
        expect {
          described_class.new(report.id, user.id).perform_now
        }.to have_enqueued_job(described_class)
      end
    end

    context "on the final failure" do
      before do
        allow_any_instance_of(Reports::PdfGenerator).to receive(:generate)
          .and_raise(StandardError, "kaboom")
      end

      # With `retry_on ... do |job, error|`, Rails invokes the block on
      # the final attempt instead of re-raising. We express final-attempt
      # behavior by calling the block handler directly rather than trying
      # to simulate Rails' internal retry counters.
      it "marks the record :failed and broadcasts failed on the user+report stream" do
        job = described_class.new(report.id, user.id)
        error = StandardError.new("kaboom")

        job.send(:on_attempts_exceeded, error)

        expect(report_pdf.reload.status_failed?).to be(true)
        expect(report_pdf.reload.error_message).to eq("StandardError: kaboom")
        expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
          "pdf_notifications:user_#{user.id}:report_#{report.id}",
          hash_including(html: a_string_matching(/data-pdf-status='failed'/))
        )
      end

      it "includes retryable flag and pdf_retry URL so the frontend can auto-retry" do
        captured = nil
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) do |_stream, **opts|
          captured = opts
        end

        job = described_class.new(report.id, user.id)
        job.send(:on_attempts_exceeded, StandardError.new("kaboom"))

        expect(captured).to be_present
        html = captured[:html]
        expect(html).to include("data-pdf-retryable='true'")
        retry_url = html[/data-retry-url='([^']+)'/, 1]
        expect(retry_url).to be_present
        expect(retry_url).to match(%r{/report_details/#{report.id}/pdf_retry\z})
      end
    end
  end

  describe "queue configuration" do
    it "uses the default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end
  end
end
