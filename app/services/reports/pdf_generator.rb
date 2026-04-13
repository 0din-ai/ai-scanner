module Reports
  class PdfGenerator
    attr_reader :report

    def initialize(report)
      @report = report
      @temp_pdf_path = nil
    end

    def generate
      begin
        # Prefer ENV_PORT (entrypoint invariant) over PORT (which some servers mutate)
        port = ENV["ENV_PORT"].presence || ENV["PORT"].presence || "3000"

        # Generate a short-lived signed token so the headless browser can access
        # the report without a Devise session.
        token = Rails.application.message_verifier("pdf").generate(
          report.id,
          expires_in: 5.minutes,
          purpose: :pdf_render
        )

        url = Rails.application.routes.url_helpers.report_detail_url(
          report,
          host: "localhost",
          port: port,
          protocol: "http",
          params: { pdf: true, pdf_token: token }
        )

        # Generate PDF using PlaywrightService
        playwright_service = BrowserAutomation::PlaywrightService.instance
        @temp_pdf_path = playwright_service.generate_pdf(
          url,
          nil, # Let it generate temp path
          {
            width: 1200,
            height: 1600,
            format: "A4",
            print_background: true,
            prefer_css_page_size: true,
            timeout: 20000,
            allow_localhost: true
          }
        )

        # Read the PDF content
        pdf_content = File.binread(@temp_pdf_path)

        pdf_content
      rescue => e
        Rails.logger.error("PDF generation failed for report #{report.id}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        raise
      ensure
        cleanup_temp_file
      end
    end

    def filename
      "#{report.target_name}_#{report.created_at.strftime('%Y-%m-%d')}.pdf"
    end

    private

    def cleanup_temp_file
      return unless @temp_pdf_path

      begin
        File.delete(@temp_pdf_path) if File.exist?(@temp_pdf_path)
        Rails.logger.info("Cleaned up temporary PDF file for report #{report.id}")
      rescue => e
        Rails.logger.error("Error cleaning up temporary PDF file: #{e.message}")
      end
    end
  end
end
