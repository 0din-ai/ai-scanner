require 'rails_helper'

RSpec.describe Reports::PdfGenerator do
  let(:report) do
    double('report',
      id: 123,
      target_name: 'example.com',
      created_at: Time.new(2025, 5, 12)
    )
  end
  let(:generator) { described_class.new(report) }
  let(:playwright_service) { instance_double(BrowserAutomation::PlaywrightService) }
  let(:pdf_content) { 'PDF binary content' }
  let(:temp_pdf_path) { Rails.root.join('tmp', 'pdfs', 'test_report.pdf') }
  let(:url) { 'http://localhost:3000/report_details/123?pdf=true' }

  before do
    allow(BrowserAutomation::PlaywrightService).to receive(:instance).and_return(playwright_service)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)

    url_helpers = double('url_helpers')
    allow(Rails.application.routes).to receive(:url_helpers).and_return(url_helpers)
    allow(url_helpers).to receive(:report_detail_url).and_return(url)
  end

  describe '#initialize' do
    it 'sets the report attribute' do
      expect(generator.report).to eq(report)
    end
  end

  describe '#filename' do
    it 'returns a filename with target name and date' do
      expected_filename = "example.com_2025-05-12.pdf"
      expect(generator.filename).to eq(expected_filename)
    end
  end

  describe '#generate' do
    before do
      allow(playwright_service).to receive(:generate_pdf).and_return(temp_pdf_path)
      allow(File).to receive(:binread).with(temp_pdf_path).and_return(pdf_content)
      allow(File).to receive(:exist?).with(temp_pdf_path).and_return(true)
      allow(File).to receive(:delete).with(temp_pdf_path)
    end

    it 'generates a PDF using PlaywrightService' do
      result = generator.generate

      expect(playwright_service).to have_received(:generate_pdf).with(
        url,
        nil,
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

      expect(File).to have_received(:binread).with(temp_pdf_path)
      expect(result).to eq(pdf_content)
    end

    it 'cleans up temporary PDF file' do
      generator.generate

      expect(File).to have_received(:delete).with(temp_pdf_path)
      expect(Rails.logger).to have_received(:info).with("Cleaned up temporary PDF file for report 123")
    end

    context 'when PDF generation fails' do
      before do
        allow(playwright_service).to receive(:generate_pdf).and_raise(StandardError.new("PDF generation failed"))
      end

      it 'logs the error and re-raises' do
        expect { generator.generate }.to raise_error(StandardError, "PDF generation failed")

        expect(Rails.logger).to have_received(:error).with("PDF generation failed for report 123: PDF generation failed")
        # Backtrace is also logged - expect at least 2 error calls total
        expect(Rails.logger).to have_received(:error).at_least(:twice)
      end
    end

    context 'when file cleanup fails' do
      before do
        allow(File).to receive(:delete).and_raise(StandardError.new("Permission denied"))
      end

      it 'logs cleanup error but still returns PDF content' do
        result = generator.generate

        expect(result).to eq(pdf_content)
        expect(Rails.logger).to have_received(:error).with("Error cleaning up temporary PDF file: Permission denied")
      end
    end

    context 'when temporary file does not exist' do
      before do
        allow(File).to receive(:exist?).with(temp_pdf_path).and_return(false)
      end

      it 'does not attempt to delete the file' do
        generator.generate

        expect(File).not_to have_received(:delete)
      end
    end
  end
end
