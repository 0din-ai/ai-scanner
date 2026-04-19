class ReportDetailsController < ApplicationController
  SHOW_INCLUDES = [ :target, :scan, probe_results: [ :probe, :detector ] ].freeze

  skip_before_action :authenticate_user!, only: [ :show ]
  skip_before_action :set_tenant, only: [ :show ]
  before_action :authenticate_show, only: [ :show ]
  before_action :set_show_tenant, only: [ :show ]
  before_action :set_report

  def show
  end

  def pdf
    if params[:pdf_token].present?
      serve_downloadable_pdf
    else
      serve_status_or_enqueue
    end
  end

  def pdf_retry
    report_pdf = @report.report_pdf

    # Already-downloadable or already-running requests don't need a reset.
    # Respond with the normal status so the client can just poll or download.
    return if report_pdf && render_report_pdf_status_for_retry(report_pdf)

    report_pdf&.destroy!

    begin
      @report.create_report_pdf!(status: :pending)
    rescue ActiveRecord::RecordNotUnique
      @report.reload
      existing = @report.report_pdf
      return if existing && render_report_pdf_status_for_retry(existing)
      raise
    end

    GeneratePdfJob.perform_later(@report.id, current_user.id)

    render json: {
      status: "pending",
      message: "PDF generation started. Please wait..."
    }, status: :accepted
  end

  private

  def serve_downloadable_pdf
    report_pdf = @report.report_pdf
    return head :not_found unless report_pdf&.ready?
    return head :not_found unless Reports::PdfDownloadToken.verify(params[:pdf_token], report_pdf)
    return head :not_found unless report_pdf.downloadable?

    safe_path = Reports::PdfStorage.safe_path(report_pdf.file_path)
    return head :not_found unless safe_path
    return head :not_found unless File.exist?(safe_path)

    DeletePdfJob.set(wait: 2.minutes).perform_later(report_pdf.id) if report_pdf.claim_download!

    send_file safe_path,
              filename: pdf_filename,
              type: "application/pdf",
              disposition: "attachment"
  end

  def serve_status_or_enqueue
    report_pdf = @report.report_pdf

    return if render_report_pdf_status(report_pdf)

    report_pdf&.destroy!

    begin
      @report.create_report_pdf!(status: :pending)
    rescue ActiveRecord::RecordNotUnique
      @report.reload
      existing = @report.report_pdf
      return if existing && render_report_pdf_status(existing)
      raise
    end

    GeneratePdfJob.perform_later(@report.id, current_user.id)

    render json: {
      status: "pending",
      message: "PDF generation started. Please wait..."
    }, status: :accepted
  end

  def render_report_pdf_status(report_pdf)
    return false unless report_pdf

    if report_pdf.downloadable?
      token = Reports::PdfDownloadToken.generate(report_pdf)
      render json: {
        status: "ready",
        download_url: pdf_report_detail_path(@report, pdf_token: token)
      }, status: :ok
      return true
    end

    if report_pdf.status_processing? || report_pdf.status_pending?
      render json: {
        status: report_pdf.status,
        message: "PDF is being generated. Please wait..."
      }, status: :accepted
      return true
    end

    if report_pdf.status_failed?
      render json: {
        status: "failed",
        message: report_pdf.error_message.presence || "PDF generation failed",
        retryable: true,
        retry_url: pdf_retry_report_detail_path(@report)
      }, status: :unprocessable_entity
      return true
    end

    false
  end

  # Retry should treat the failed state as "rerun this", so we only
  # short-circuit for the already-good and in-flight states.
  def render_report_pdf_status_for_retry(report_pdf)
    return false if report_pdf.status_failed?

    render_report_pdf_status(report_pdf)
  end

  def set_report
    report = @_unscoped_report || Report.includes(*SHOW_INCLUDES).find(params[:id])
    @report = ReportDecorator.new(report)
  end

  def pdf_filename
    "#{@report.target_name}_#{@report.created_at.strftime('%Y-%m-%d')}.pdf"
  end

  # Verify a short-lived signed token from the internal PDF renderer.
  # This allows the headless browser to access the report without a Devise session.
  def valid_pdf_render_token?
    return @_valid_pdf_render_token if defined?(@_valid_pdf_render_token)

    @_valid_pdf_render_token = if params[:pdf_token].present? && params[:pdf].present?
      report_id = Rails.application.message_verifier(
        Reports::PdfGenerator::RENDER_TOKEN_VERIFIER_KEY
      ).verify(
        params[:pdf_token],
        purpose: Reports::PdfGenerator::RENDER_TOKEN_PURPOSE
      )
      report_id.to_s == params[:id].to_s
    else
      false
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    @_valid_pdf_render_token = false
  end

  def authenticate_show
    return if valid_pdf_render_token?

    redirect_to new_user_session_path unless current_user
  end

  def set_show_tenant
    if valid_pdf_render_token?
      @_unscoped_report = Report.includes(*SHOW_INCLUDES).find(params[:id])
      ActsAsTenant.current_tenant = @_unscoped_report.company
    else
      set_tenant
    end
  end
end
