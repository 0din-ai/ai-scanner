# frozen_string_literal: true

class DeletePdfJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  def perform(report_pdf_id)
    report_pdf = ReportPdf.find(report_pdf_id)

    safe_path = Reports::PdfStorage.safe_path(report_pdf.file_path)

    if safe_path && File.exist?(safe_path)
      File.delete(safe_path)
      Rails.logger.info("Deleted PDF after download: report_pdf=#{report_pdf.id} path=#{safe_path}")
    end

    report_pdf.destroy
  end
end
