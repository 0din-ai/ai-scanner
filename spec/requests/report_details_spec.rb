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
        Rails.application.message_verifier("pdf").generate(
          report.id,
          expires_in: 5.minutes,
          purpose: :pdf_render
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
        Rails.application.message_verifier("pdf").generate(
          report.id,
          expires_at: 1.minute.ago,
          purpose: :pdf_render
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
      Rails.application.message_verifier("pdf").generate(
        report.id,
        expires_in: 5.minutes,
        purpose: :pdf_render
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
end
