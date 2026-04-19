# frozen_string_literal: true

class CleanupOldPdfsJob < ApplicationJob
  queue_as :low_priority

  def perform
    old_pdfs = ReportPdf.stale(24)
    count = 0

    old_pdfs.find_each do |report_pdf|
      begin
        safe_path = Reports::PdfStorage.safe_path(report_pdf.file_path)
        if safe_path && File.exist?(safe_path)
          File.delete(safe_path)
          Rails.logger.info("Deleted old PDF file: #{safe_path}")
        end

        report_pdf.destroy
        count += 1
      rescue => e
        Rails.logger.error("Failed to cleanup PDF #{report_pdf.id}: #{e.message}")
      end
    end

    Rails.logger.info("Cleaned up #{count} old PDF files")
  end
end
