# frozen_string_literal: true

class GeneratePdfJob < ApplicationJob
  MAX_ATTEMPTS = 3

  queue_as :default

  limits_concurrency to: 1,
    key: ->(report_id, _user_id = nil) { "generate_pdf_#{report_id}" },
    on_conflict: :discard

  # Mid-retry: retry_on re-enqueues without touching the ReportPdf row, so it stays
  # in :processing across attempts (avoiding a rebuild loop on the client).
  # Final attempt: the block runs, marking the record :failed and broadcasting.
  retry_on StandardError, wait: :polynomially_longer, attempts: MAX_ATTEMPTS do |job, error|
    job.send(:on_attempts_exceeded, error)
  end

  discard_on ActiveRecord::RecordNotFound

  def perform(report_id, user_id)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    report = Report.find(report_id)
    report_pdf = report.report_pdf

    return if report_pdf.nil?
    return if report_pdf.ready?

    report_pdf.update!(status: :processing) unless report_pdf.status_processing?

    file_path = write_pdf(report)

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

    report_pdf.update!(status: :completed, file_path: file_path, error_message: nil)

    Rails.logger.info(
      "Successfully generated PDF for report #{report_id} at #{file_path} in #{duration_ms}ms"
    )

    collect_metrics(report, duration_ms, File.size(file_path), success: true)

    broadcast_pdf_ready(report, report_pdf.reload, user_id)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    Rails.logger.error("PDF generation failed for report #{report_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    collect_metrics(report, 0, 0, success: false, error: e.class.name) if defined?(report) && report
    raise
  end

  private

  def on_attempts_exceeded(error)
    report_id, user_id = arguments
    report = Report.find_by(id: report_id)
    return unless report

    report_pdf = report.report_pdf
    return unless report_pdf

    report_pdf.update!(status: :failed, error_message: "#{error.class}: #{error.message}")
    broadcast_pdf_failed(report, user_id, error)
  end

  def write_pdf(report)
    storage_dir = Rails.root.join("storage", "pdfs")
    FileUtils.mkdir_p(storage_dir)

    file_path = storage_dir.join("report_#{report.id}.pdf").to_s
    pdf_content = Reports::PdfGenerator.new(ReportDecorator.new(report)).generate
    File.binwrite(file_path, pdf_content)
    file_path
  end

  def broadcast_pdf_ready(report, report_pdf, user_id)
    token = Reports::PdfDownloadToken.generate(report_pdf)
    download_url = Rails.application.routes.url_helpers.pdf_report_detail_path(report, pdf_token: token)
    escaped_url = ERB::Util.html_escape(download_url)

    Turbo::StreamsChannel.broadcast_replace_to(
      stream_name_for(report, user_id),
      target: "pdf-status-#{report.id}",
      html: <<~HTML.squish
        <div id='pdf-status-#{report.id}' style='display: none;'
             data-pdf-status='ready'
             data-download-url='#{escaped_url}'></div>
      HTML
    )
  end

  def broadcast_pdf_failed(report, user_id, error)
    escaped_error = ERB::Util.html_escape("#{error.class}: #{error.message}")
    retry_url = Rails.application.routes.url_helpers.pdf_retry_report_detail_path(report)
    escaped_retry_url = ERB::Util.html_escape(retry_url)

    Turbo::StreamsChannel.broadcast_replace_to(
      stream_name_for(report, user_id),
      target: "pdf-status-#{report.id}",
      html: <<~HTML.squish
        <div id='pdf-status-#{report.id}' style='display: none;'
             data-pdf-status='failed'
             data-pdf-error='#{escaped_error}'
             data-pdf-retryable='true'
             data-retry-url='#{escaped_retry_url}'></div>
      HTML
    )
  end

  def stream_name_for(report, user_id)
    "pdf_notifications:user_#{user_id}:report_#{report.id}"
  end

  def collect_metrics(report, duration_ms, pdf_size_bytes, success:, error: nil)
    return unless MonitoringService.active?

    labels = {
      report_id: report.id,
      report_uuid: report.uuid,
      target_name: report.target.name,
      scan_name: report.scan.name,
      pdf_generation_duration_ms: duration_ms,
      pdf_generation_success: success ? 1 : 0,
      pdf_size_bytes: pdf_size_bytes
    }

    labels[:pdf_generation_error] = error if error

    MonitoringService.set_labels(labels)

    Rails.logger.info(
      "[Metrics] PDF generation: report=#{report.id} duration=#{duration_ms}ms " \
      "size=#{pdf_size_bytes}bytes success=#{success}"
    )
  end
end
