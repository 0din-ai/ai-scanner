require 'rails_helper'

RSpec.describe ReportDetailsController, type: :controller do
  let(:user) { create(:user) }
  let(:report) { instance_double(Report, id: 1, to_param: "1") }
  let(:decorated_report) do
    double('ReportDecorator', __getobj__: report, id: 1, to_param: "1")
  end

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
    before do
      allow(decorated_report).to receive(:target_name).and_return('test_target')
      allow(decorated_report).to receive(:created_at).and_return(Time.zone.parse('2026-01-01'))
    end

    context 'without a pdf_token (status-or-enqueue)' do
      context 'when the PDF is downloadable' do
        let(:report_pdf) do
          instance_double(ReportPdf,
            id: 77,
            downloadable?: true,
            status_processing?: false,
            status_pending?: false)
        end

        before do
          allow(decorated_report).to receive(:report_pdf).and_return(report_pdf)
          allow(Reports::PdfDownloadToken).to receive(:generate).with(report_pdf).and_return('signed-token')
        end

        it 'returns 200 with ready status and a signed download_url containing pdf_token' do
          get :pdf, params: { id: 1 }

          expect(response).to have_http_status(:ok)
          json = JSON.parse(response.body)
          expect(json['status']).to eq('ready')
          expect(json['download_url']).to include('pdf_token=signed-token')
          expect(json['download_url']).to match(%r{/report_details/1/pdf})
        end
      end

      context 'when the PDF is processing' do
        let(:report_pdf) do
          instance_double(ReportPdf,
            downloadable?: false,
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

      context 'when the PDF is pending' do
        let(:report_pdf) do
          instance_double(ReportPdf,
            downloadable?: false,
            status_processing?: false,
            status_pending?: true,
            status: 'pending')
        end

        before do
          allow(decorated_report).to receive(:report_pdf).and_return(report_pdf)
        end

        it 'returns 202 with pending status' do
          get :pdf, params: { id: 1 }

          expect(response).to have_http_status(:accepted)
          json = JSON.parse(response.body)
          expect(json['status']).to eq('pending')
        end
      end

      context 'when no PDF record exists yet' do
        let(:new_report_pdf) { instance_double(ReportPdf, save!: true) }

        before do
          allow(decorated_report).to receive(:report_pdf).and_return(nil)
          allow(decorated_report).to receive(:create_report_pdf!).with(status: :pending).and_return(new_report_pdf)
          allow(GeneratePdfJob).to receive(:perform_later)
        end

        it 'creates a pending record, enqueues GeneratePdfJob with report_id and user_id, and returns 202' do
          get :pdf, params: { id: 1 }

          expect(decorated_report).to have_received(:create_report_pdf!).with(status: :pending)
          expect(GeneratePdfJob).to have_received(:perform_later).with(1, user.id)
          expect(response).to have_http_status(:accepted)
          json = JSON.parse(response.body)
          expect(json['status']).to eq('pending')
        end
      end

      context 'when an existing record is stale (not downloadable, not processing/pending/failed)' do
        let(:stale_report_pdf) do
          instance_double(ReportPdf,
            id: 99,
            downloadable?: false,
            status_processing?: false,
            status_pending?: false,
            status_failed?: false,
            destroy!: true)
        end
        let(:new_report_pdf) { instance_double(ReportPdf, save!: true) }

        before do
          allow(decorated_report).to receive(:report_pdf).and_return(stale_report_pdf)
          allow(decorated_report).to receive(:create_report_pdf!).with(status: :pending).and_return(new_report_pdf)
          allow(GeneratePdfJob).to receive(:perform_later)
        end

        it 'destroys the stale record, creates a new one, enqueues, and returns 202 pending' do
          get :pdf, params: { id: 1 }

          expect(stale_report_pdf).to have_received(:destroy!)
          expect(decorated_report).to have_received(:create_report_pdf!).with(status: :pending)
          expect(GeneratePdfJob).to have_received(:perform_later).with(1, user.id)
          expect(response).to have_http_status(:accepted)
        end
      end

      context 'when the PDF is in a failed terminal state' do
        let(:failed_report_pdf) do
          instance_double(ReportPdf,
            id: 55,
            downloadable?: false,
            status_processing?: false,
            status_pending?: false,
            status_failed?: true,
            status: 'failed',
            error_message: 'Timeout::Error: rendering took too long')
        end

        before do
          allow(decorated_report).to receive(:report_pdf).and_return(failed_report_pdf)
          allow(decorated_report).to receive(:create_report_pdf!)
          allow(GeneratePdfJob).to receive(:perform_later)
        end

        it 'returns a 422 failed JSON with a retryable flag + retry_url and does not enqueue a new job' do
          get :pdf, params: { id: 1 }

          expect(response).to have_http_status(:unprocessable_entity)
          json = JSON.parse(response.body)
          expect(json['status']).to eq('failed')
          expect(json['message']).to include('Timeout::Error')
          expect(json['retryable']).to eq(true)
          expect(json['retry_url']).to match(%r{/report_details/1/pdf_retry})

          expect(failed_report_pdf).not_to have_received(:destroy!) if failed_report_pdf.respond_to?(:destroy!)
          expect(decorated_report).not_to have_received(:create_report_pdf!)
          expect(GeneratePdfJob).not_to have_received(:perform_later)
        end

        context 'when error_message is blank' do
          let(:failed_report_pdf) do
            instance_double(ReportPdf,
              id: 56,
              downloadable?: false,
              status_processing?: false,
              status_pending?: false,
              status_failed?: true,
              status: 'failed',
              error_message: nil)
          end

          it 'still returns 422 failed with a generic fallback message' do
            get :pdf, params: { id: 1 }

            expect(response).to have_http_status(:unprocessable_entity)
            json = JSON.parse(response.body)
            expect(json['status']).to eq('failed')
            expect(json['message']).to be_present
          end
        end
      end

      context 'when another request wins the create race with a unique-index violation' do
        let(:existing_processing_pdf) do
          instance_double(ReportPdf,
            id: 88,
            downloadable?: false,
            status_processing?: true,
            status_pending?: false,
            status_failed?: false,
            status: 'processing')
        end

        before do
          call_count = 0
          allow(decorated_report).to receive(:report_pdf) do
            call_count += 1
            call_count == 1 ? nil : existing_processing_pdf
          end
          allow(decorated_report).to receive(:reload).and_return(decorated_report)
          allow(decorated_report).to receive(:create_report_pdf!).with(status: :pending)
            .and_raise(ActiveRecord::RecordNotUnique.new('duplicate key value'))
          allow(GeneratePdfJob).to receive(:perform_later)
        end

        it 'fetches the existing row and returns 202 without enqueuing a duplicate job' do
          get :pdf, params: { id: 1 }

          expect(response).to have_http_status(:accepted)
          json = JSON.parse(response.body)
          expect(json['status']).to eq('processing')
          expect(GeneratePdfJob).not_to have_received(:perform_later)
        end
      end
    end

    context 'with a pdf_token (serve_downloadable_pdf)' do
      let(:sandbox_path) { Rails.root.join('storage', 'pdfs', 'report_1.pdf').to_s }
      let(:report_pdf) do
        instance_double(ReportPdf,
          id: 42,
          ready?: true,
          file_path: sandbox_path,
          downloadable?: true)
      end

      before do
        allow(decorated_report).to receive(:report_pdf).and_return(report_pdf)
      end

      context 'when the user is not signed in' do
        before do
          sign_out user
          allow(controller).to receive(:send_file)
        end

        it 'redirects to sign in and does not serve the file' do
          get :pdf, params: { id: 1, pdf_token: 'good-token' }

          expect(response).to redirect_to(new_user_session_path)
          expect(controller).not_to have_received(:send_file)
        end
      end

      context 'when token is valid, file in sandbox, and claim succeeds' do
        before do
          allow(Reports::PdfDownloadToken).to receive(:verify).with('good-token', report_pdf).and_return(true)
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(true)
          allow(report_pdf).to receive(:claim_download!).and_return(true)
          allow(DeletePdfJob).to receive_message_chain(:set, :perform_later)
          allow(controller).to receive(:send_file) { controller.head :ok }
        end

        it 'sends the PDF and schedules DeletePdfJob' do
          get :pdf, params: { id: 1, pdf_token: 'good-token' }

          expect(controller).to have_received(:send_file).with(
            File.expand_path(sandbox_path),
            filename: 'test_target_2026-01-01.pdf',
            type: 'application/pdf',
            disposition: 'attachment'
          )
          expect(DeletePdfJob).to have_received(:set).with(wait: 2.minutes)
        end
      end

      context 'when claim_download! returns false (within grace-window re-download)' do
        before do
          allow(Reports::PdfDownloadToken).to receive(:verify).with('good-token', report_pdf).and_return(true)
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(File.expand_path(sandbox_path)).and_return(true)
          allow(report_pdf).to receive(:claim_download!).and_return(false)
          allow(DeletePdfJob).to receive(:set)
          allow(controller).to receive(:send_file) { controller.head :ok }
        end

        it 'still serves the file but does NOT enqueue DeletePdfJob' do
          get :pdf, params: { id: 1, pdf_token: 'good-token' }

          expect(controller).to have_received(:send_file)
          expect(DeletePdfJob).not_to have_received(:set)
        end
      end

      context 'when token is invalid' do
        before do
          allow(Reports::PdfDownloadToken).to receive(:verify).with('bad-token', report_pdf).and_return(false)
          allow(controller).to receive(:send_file)
        end

        it 'returns 404 and does not send_file' do
          get :pdf, params: { id: 1, pdf_token: 'bad-token' }

          expect(response).to have_http_status(:not_found)
          expect(controller).not_to have_received(:send_file)
        end
      end

      context 'when report_pdf.downloadable? is false' do
        before do
          allow(report_pdf).to receive(:downloadable?).and_return(false)
          allow(Reports::PdfDownloadToken).to receive(:verify).with('good-token', report_pdf).and_return(true)
          allow(controller).to receive(:send_file)
        end

        it 'returns 404 and does not send_file' do
          get :pdf, params: { id: 1, pdf_token: 'good-token' }

          expect(response).to have_http_status(:not_found)
          expect(controller).not_to have_received(:send_file)
        end
      end

      context 'when file_path is outside the storage/pdfs sandbox' do
        let(:report_pdf) do
          instance_double(ReportPdf,
            id: 42,
            ready?: true,
            file_path: '/etc/passwd',
            downloadable?: true)
        end

        before do
          allow(Reports::PdfDownloadToken).to receive(:verify).with('good-token', report_pdf).and_return(true)
          allow(controller).to receive(:send_file)
        end

        it 'returns 404 and does not send_file' do
          get :pdf, params: { id: 1, pdf_token: 'good-token' }

          expect(response).to have_http_status(:not_found)
          expect(controller).not_to have_received(:send_file)
        end
      end

      context 'when report_pdf is nil' do
        before do
          allow(decorated_report).to receive(:report_pdf).and_return(nil)
          allow(controller).to receive(:send_file)
        end

        it 'returns 404' do
          get :pdf, params: { id: 1, pdf_token: 'good-token' }

          expect(response).to have_http_status(:not_found)
          expect(controller).not_to have_received(:send_file)
        end
      end
    end
  end

  describe '#pdf_retry' do
    context 'when another request wins the create race with a unique-index violation' do
      let(:existing_processing_pdf) do
        instance_double(ReportPdf,
          id: 123,
          downloadable?: false,
          status_processing?: true,
          status_pending?: false,
          status_failed?: false,
          status: 'processing')
      end

      before do
        call_count = 0
        allow(decorated_report).to receive(:report_pdf) do
          call_count += 1
          call_count == 1 ? nil : existing_processing_pdf
        end
        allow(decorated_report).to receive(:reload).and_return(decorated_report)
        allow(decorated_report).to receive(:create_report_pdf!).with(status: :pending)
          .and_raise(ActiveRecord::RecordNotUnique.new('duplicate key value'))
        allow(GeneratePdfJob).to receive(:perform_later)
      end

      it 'fetches the existing row and returns 202 without enqueuing a duplicate job' do
        post :pdf_retry, params: { id: 1 }

        expect(response).to have_http_status(:accepted)
        json = JSON.parse(response.body)
        expect(json['status']).to eq('processing')
        expect(GeneratePdfJob).not_to have_received(:perform_later)
      end
    end
  end
end
