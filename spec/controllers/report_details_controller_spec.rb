require 'rails_helper'

RSpec.describe ReportDetailsController, type: :controller do
  let(:user) { create(:user) }
  let(:report) { instance_double(Report, id: 1) }
  let(:decorated_report) { double('ReportDecorator', __getobj__: report) }

  before do
    sign_in user
    report_scope = double("Report::Relation")
    allow(Report).to receive(:includes).with(*ReportDetailsController::SHOW_INCLUDES).and_return(report_scope)
    allow(report_scope).to receive(:find).with("1").and_return(report)
    allow(ReportDecorator).to receive(:new).with(report).and_return(decorated_report)
  end

  describe '#show' do
    it 'renders the show template with status 200' do
      get :show, params: { id: 1 }

      expect(ReportDecorator).to have_received(:new).with(report)
      expect(response).to have_http_status(:ok)
    end
  end

  describe '#pdf' do
    let(:pdf_filename) { 'report.pdf' }

    before do
      allow(decorated_report).to receive(:id).and_return(1)
      allow(decorated_report).to receive(:target_name).and_return('test_target')
      allow(decorated_report).to receive(:created_at).and_return(Time.zone.parse('2026-01-01'))
    end

    context 'when PDF is ready' do
      let(:report_pdf) { instance_double(ReportPdf, ready?: true, file_path: '/tmp/test.pdf') }

      before do
        allow(decorated_report).to receive(:report_pdf).and_return(report_pdf)
        allow(controller).to receive(:send_file) { controller.head :ok }
      end

      it 'sends the PDF file' do
        get :pdf, params: { id: 1 }

        expect(controller).to have_received(:send_file).with(
          '/tmp/test.pdf',
          filename: 'test_target_2026-01-01.pdf',
          type: 'application/pdf',
          disposition: 'attachment'
        )
      end
    end

    context 'when PDF is being generated' do
      let(:report_pdf) do
        instance_double(ReportPdf,
          ready?: false,
          status_processing?: true,
          status_pending?: false,
          status: 'processing')
      end

      before do
        allow(decorated_report).to receive(:report_pdf).and_return(report_pdf)
      end

      it 'returns 202 with processing status' do
        get :pdf, params: { id: 1 }

        expect(response).to have_http_status(:accepted)
        json = JSON.parse(response.body)
        expect(json['status']).to eq('processing')
      end
    end

    context 'when PDF does not exist' do
      let(:new_report_pdf) { instance_double(ReportPdf, save!: true) }

      before do
        allow(decorated_report).to receive(:report_pdf).and_return(nil)
        allow(decorated_report).to receive(:build_report_pdf).with(status: :pending).and_return(new_report_pdf)
        allow(GeneratePdfJob).to receive(:perform_later)
      end

      it 'creates ReportPdf record, starts PDF generation and returns pending status' do
        get :pdf, params: { id: 1 }

        expect(decorated_report).to have_received(:build_report_pdf).with(status: :pending)
        expect(new_report_pdf).to have_received(:save!)
        expect(GeneratePdfJob).to have_received(:perform_later).with(1)
        expect(response).to have_http_status(:accepted)
        json = JSON.parse(response.body)
        expect(json['status']).to eq('pending')
      end
    end
  end

  describe '#pdf_status' do
    context 'when PDF is ready' do
      let(:report_pdf) do
        instance_double(ReportPdf,
          ready?: true,
          status_failed?: false)
      end

      before do
        allow(decorated_report).to receive(:report_pdf).and_return(report_pdf)
      end

      it 'returns completed status with download URL' do
        get :pdf_status, params: { id: 1 }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json['status']).to eq('completed')
        expect(json['download_url']).to be_present
      end
    end

    context 'when PDF generation failed' do
      let(:report_pdf) do
        instance_double(ReportPdf,
          ready?: false,
          status_failed?: true,
          error_message: 'Generation failed')
      end

      before do
        allow(decorated_report).to receive(:report_pdf).and_return(report_pdf)
      end

      it 'returns failed status with error' do
        get :pdf_status, params: { id: 1 }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json['status']).to eq('failed')
        expect(json['error']).to eq('Generation failed')
      end
    end

    context 'when PDF does not exist' do
      before do
        allow(decorated_report).to receive(:report_pdf).and_return(nil)
      end

      it 'returns not_found status' do
        get :pdf_status, params: { id: 1 }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json['status']).to eq('not_found')
      end
    end
  end
end
