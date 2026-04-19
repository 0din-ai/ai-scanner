require 'rails_helper'

RSpec.describe "ReportDetails", type: :request do
  let(:company) { create(:company) }
  let(:report) { create(:report, :completed, company: company) }

  describe "GET /report_details/:id (cross-tenant isolation)" do
    let(:company_a) { create(:company) }
    let(:company_b) { create(:company) }
    let(:user_a) { create(:user, company: company_a) }
    let(:report_b) { create(:report, :completed, company: company_b) }

    it "prevents Company-A user from viewing Company-B report" do
      sign_in user_a
      get report_detail_path(report_b)
      expect(response).to have_http_status(:not_found)
    end

    it "allows a user to view their own company report when detector results are present" do
      report_a = create(:report, :completed, company: company_a)
      create(:detector_result, report: report_a, passed: 3, total: 10)

      sign_in user_a
      get report_detail_path(report_a)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /report_details/:id (anonymous)" do
    context "without any token" do
      it "redirects to sign in instead of returning 500" do
        get report_detail_path(report)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "with pdf=true and a valid pdf_token" do
      let!(:detector_result) { create(:detector_result, report: report, passed: 3, total: 10) }

      let(:pdf_token) do
        Rails.application.message_verifier(Reports::PdfGenerator::RENDER_TOKEN_VERIFIER_KEY).generate(
          report.id,
          expires_in: Reports::PdfGenerator::RENDER_TOKEN_TTL,
          purpose: Reports::PdfGenerator::RENDER_TOKEN_PURPOSE
        )
      end

      it "renders the show page successfully" do
        get report_detail_path(report, pdf: "true", pdf_token: pdf_token)

        expect(response).to have_http_status(:ok)
      end
    end

    context "with pdf=true but an invalid pdf_token" do
      it "redirects to sign in" do
        get report_detail_path(report, pdf: "true", pdf_token: "invalid-token")

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "with pdf=true and an expired pdf_token" do
      let(:expired_token) do
        Rails.application.message_verifier(Reports::PdfGenerator::RENDER_TOKEN_VERIFIER_KEY).generate(
          report.id,
          expires_at: 1.minute.ago,
          purpose: Reports::PdfGenerator::RENDER_TOKEN_PURPOSE
        )
      end

      it "redirects to sign in" do
        get report_detail_path(report, pdf: "true", pdf_token: expired_token)

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "GET /report_details/:id with nil probe_result attempts" do
    let!(:probe_result) do
      create(:probe_result, report: report, passed: 3, total: 10)
    end

    let(:pdf_token) do
      Rails.application.message_verifier(Reports::PdfGenerator::RENDER_TOKEN_VERIFIER_KEY).generate(
        report.id,
        expires_in: Reports::PdfGenerator::RENDER_TOKEN_TTL,
        purpose: Reports::PdfGenerator::RENDER_TOKEN_PURPOSE
      )
    end

    before do
      ActiveRecord::Base.connection.execute("ALTER TABLE probe_results ALTER COLUMN attempts DROP NOT NULL")
      probe_result.update_column(:attempts, nil)
    end

    after do
      ActiveRecord::Base.connection.execute(
        "UPDATE probe_results SET attempts = '[]' WHERE attempts IS NULL"
      )
      ActiveRecord::Base.connection.execute("ALTER TABLE probe_results ALTER COLUMN attempts SET NOT NULL")
    end

    it "renders successfully even when probe_result.attempts is NULL in the database" do
      get report_detail_path(report, pdf: "true", pdf_token: pdf_token)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /report_details/:id/pdf_retry" do
    let(:user) { create(:user, company: company) }

    context "when the existing report_pdf is failed" do
      before do
        sign_in user
        ActsAsTenant.with_tenant(company) do
          create(:report_pdf,
                 report: report,
                 status: :failed,
                 error_message: "Timeout::Error")
        end
      end

      it "replaces the failed record with a fresh pending one and enqueues a new job" do
        expect {
          post pdf_retry_report_detail_path(report)
        }.to change {
          ActiveJob::Base.queue_adapter.enqueued_jobs.count { |j| j[:job] == GeneratePdfJob }
        }.by(1)

        expect(response).to have_http_status(:accepted)
        json = JSON.parse(response.body)
        expect(json["status"]).to eq("pending")

        expect(report.reload.report_pdf.status).to eq("pending")
      end
    end

    context "when no report_pdf exists yet" do
      before { sign_in user }

      it "creates a pending record and enqueues generation" do
        expect {
          post pdf_retry_report_detail_path(report)
        }.to change {
          ActiveJob::Base.queue_adapter.enqueued_jobs.count { |j| j[:job] == GeneratePdfJob }
        }.by(1)

        expect(response).to have_http_status(:accepted)
        expect(report.reload.report_pdf.status).to eq("pending")
      end
    end

    context "when the record is already processing" do
      before do
        sign_in user
        ActsAsTenant.with_tenant(company) do
          create(:report_pdf, report: report, status: :processing)
        end
      end

      it "does not enqueue a duplicate job and returns the in-flight status" do
        expect {
          post pdf_retry_report_detail_path(report)
        }.not_to change {
          ActiveJob::Base.queue_adapter.enqueued_jobs.count { |j| j[:job] == GeneratePdfJob }
        }

        expect(response).to have_http_status(:accepted)
        json = JSON.parse(response.body)
        expect(json["status"]).to eq("processing")
      end
    end

    context "when the record is completed and ready" do
      before do
        sign_in user
        ActsAsTenant.with_tenant(company) do
          create(:report_pdf, :completed, report: report)
        end
        pdf = report.report_pdf
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(pdf.file_path).and_return(true)
      end

      it "returns 200 with ready status and a signed download URL" do
        post pdf_retry_report_detail_path(report)

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["status"]).to eq("ready")
        expect(json["download_url"]).to include("pdf_token=")
      end
    end

    context "cross-tenant isolation" do
      let(:company_a) { create(:company) }
      let(:company_b) { create(:company) }
      let(:user_a) { create(:user, company: company_a) }
      let(:report_b) { create(:report, :completed, company: company_b) }

      it "prevents a Company-A user from retrying Company-B PDF generation" do
        sign_in user_a

        expect {
          post pdf_retry_report_detail_path(report_b)
        }.not_to change { ReportPdf.count }

        expect(response).to have_http_status(:not_found)
      end
    end

    context "without authentication" do
      it "rejects the request" do
        post pdf_retry_report_detail_path(report)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "GET /report_details/:id/pdf" do
    let(:user) { create(:user, company: company) }

    context "cross-tenant isolation" do
      let(:company_a) { create(:company) }
      let(:company_b) { create(:company) }
      let(:user_a) { create(:user, company: company_a) }
      let(:report_b) { create(:report, :completed, company: company_b) }

      it "prevents a Company-A user from checking Company-B PDF status" do
        sign_in user_a

        expect {
          get pdf_report_detail_path(report_b)
        }.not_to change { ReportPdf.count }

        expect(response).to have_http_status(:not_found)
      end
    end

    context "without any pdf_token" do
      context "when no ReportPdf exists yet" do
        before { sign_in user }

        it "creates a pending record, enqueues GeneratePdfJob(report.id, user.id), and returns 202" do
          expect {
            get pdf_report_detail_path(report)
          }.to change { report.reload.report_pdf }.from(nil)

          expect(response).to have_http_status(:accepted)
          json = JSON.parse(response.body)
          expect(json["status"]).to eq("pending")

          enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.find do |j|
            j[:job] == GeneratePdfJob
          end
          expect(enqueued).to be_present
          expect(enqueued[:args]).to eq([ report.id, user.id ])
        end
      end

      context "when a ready record exists" do
        before do
          sign_in user
          ActsAsTenant.with_tenant(company) do
            create(:report_pdf, :completed, report: report)
          end
          pdf = report.report_pdf
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(pdf.file_path).and_return(true)
        end

        it "returns 200 with status=ready and signed download URL carrying pdf_token" do
          get pdf_report_detail_path(report)

          expect(response).to have_http_status(:ok)
          json = JSON.parse(response.body)
          expect(json["status"]).to eq("ready")
          expect(json["download_url"]).to include("pdf_token=")
          expect(json["download_url"]).to match(%r{/report_details/#{report.id}/pdf})
        end
      end

      context "when the existing record is in the :failed terminal state" do
        before do
          sign_in user
          ActsAsTenant.with_tenant(company) do
            create(:report_pdf,
                   report: report,
                   status: :failed,
                   error_message: "Playwright::Error: boom")
          end
        end

        it "returns a 422 failed JSON flagged retryable and does not enqueue a new job" do
          expect {
            get pdf_report_detail_path(report)
          }.not_to change {
            ActiveJob::Base.queue_adapter.enqueued_jobs.count { |j| j[:job] == GeneratePdfJob }
          }

          expect(response).to have_http_status(:unprocessable_entity)
          json = JSON.parse(response.body)
          expect(json["status"]).to eq("failed")
          expect(json["message"]).to include("Playwright::Error")
          expect(json["retryable"]).to eq(true)
          expect(json["retry_url"]).to match(%r{/report_details/#{report.id}/pdf_retry})
          expect(report.reload.report_pdf.status).to eq("failed")
        end
      end

      context "when an existing completed record's file_path is outside the sandbox" do
        before do
          sign_in user
          ActsAsTenant.with_tenant(company) do
            create(:report_pdf,
                   :completed,
                   report: report,
                   file_path: "/etc/passwd")
          end
          # Even if the attacker-controlled path happens to exist, the status
          # endpoint must not flag the record as ready/downloadable.
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with("/etc/passwd").and_return(true)
        end

        it "does not return status=ready and instead replaces the record with a fresh pending one" do
          get pdf_report_detail_path(report)

          expect(response).to have_http_status(:accepted)
          json = JSON.parse(response.body)
          expect(json["status"]).to eq("pending")
          expect(json).not_to have_key("download_url")

          expect(report.reload.report_pdf.status).to eq("pending")
          expect(report.report_pdf.file_path).to be_nil
        end
      end

      context "when a stale (past-grace) completed record exists" do
        before do
          sign_in user
          ActsAsTenant.with_tenant(company) do
            create(:report_pdf, :completed, report: report, downloaded_at: 5.minutes.ago)
          end
          pdf = report.report_pdf
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(pdf.file_path).and_return(true)
        end

        it "destroys the stale record and enqueues a fresh generation" do
          get pdf_report_detail_path(report)

          expect(response).to have_http_status(:accepted)
          json = JSON.parse(response.body)
          expect(json["status"]).to eq("pending")

          enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.select do |j|
            j[:job] == GeneratePdfJob
          end
          expect(enqueued.size).to eq(1)
          expect(enqueued.first[:args]).to eq([ report.id, user.id ])

          # A brand-new pending record replaces the stale one
          expect(report.reload.report_pdf.status).to eq("pending")
        end
      end
    end

    context "with a pdf_token" do
      let!(:report_pdf) do
        ActsAsTenant.with_tenant(company) do
          create(:report_pdf, :completed, report: report)
        end
      end

      before do
        # Seed a real file inside storage/pdfs so the sandbox check passes.
        FileUtils.mkdir_p(File.dirname(report_pdf.file_path))
        File.binwrite(report_pdf.file_path, "pdf-bytes")
        sign_in user
      end

      after do
        File.delete(report_pdf.file_path) if File.exist?(report_pdf.file_path)
      end

      context "when the request is anonymous" do
        before do
          sign_out user
        end

        it "redirects to sign in instead of serving the file" do
          token = Reports::PdfDownloadToken.generate(report_pdf)

          get pdf_report_detail_path(report, pdf_token: token)

          expect(response).to redirect_to(new_user_session_path)
          expect(response.headers["Content-Type"]).not_to include("application/pdf")
        end
      end

      it "serves the file for a valid token and enqueues DeletePdfJob exactly once" do
        token = Reports::PdfDownloadToken.generate(report_pdf)

        get pdf_report_detail_path(report, pdf_token: token)

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Type"]).to include("application/pdf")

        delete_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select do |j|
          j[:job] == DeletePdfJob
        end
        expect(delete_jobs.size).to eq(1)
        expect(delete_jobs.first[:args]).to eq([ report_pdf.id ])
      end

      it "serves the file on a second (within-grace) download without scheduling a second DeletePdfJob" do
        token = Reports::PdfDownloadToken.generate(report_pdf)

        get pdf_report_detail_path(report, pdf_token: token)
        get pdf_report_detail_path(report, pdf_token: token)

        expect(response).to have_http_status(:ok)

        delete_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select do |j|
          j[:job] == DeletePdfJob
        end
        expect(delete_jobs.size).to eq(1)
      end

      it "returns 404 for a tampered token" do
        token = Reports::PdfDownloadToken.generate(report_pdf)

        get pdf_report_detail_path(report, pdf_token: "#{token}tamper")

        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 when a token generated for a different report_pdf is used" do
        other_report = create(:report, :completed, company: company)
        other_report_pdf = ActsAsTenant.with_tenant(company) do
          create(:report_pdf, :completed, report: other_report)
        end

        FileUtils.mkdir_p(File.dirname(other_report_pdf.file_path))
        File.binwrite(other_report_pdf.file_path, "other-pdf-bytes")

        token = Reports::PdfDownloadToken.generate(other_report_pdf)

        get pdf_report_detail_path(report, pdf_token: token)

        expect(response).to have_http_status(:not_found)
        expect(response.headers["Content-Type"]).not_to include("application/pdf")
      ensure
        File.delete(other_report_pdf.file_path) if other_report_pdf && File.exist?(other_report_pdf.file_path)
      end

      it "returns 404 for an expired token" do
        token = Reports::PdfDownloadToken.generate(report_pdf)

        travel_to((Reports::PdfDownloadToken::TTL + 1.minute).from_now) do
          get pdf_report_detail_path(report, pdf_token: token)
        end

        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 when the token is valid but the file is missing from disk" do
        token = Reports::PdfDownloadToken.generate(report_pdf)
        File.delete(report_pdf.file_path)

        get pdf_report_detail_path(report, pdf_token: token)

        expect(response).to have_http_status(:not_found)
        expect(response.headers["Content-Type"]).not_to include("application/pdf")
      end
    end
  end
end
