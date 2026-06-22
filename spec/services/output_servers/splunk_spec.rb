require 'rails_helper'

RSpec.describe OutputServers::Splunk do
  let(:output_server) { instance_double(OutputServer,
                                        server_type: 'splunk',
                                        protocol: 'https',
                                        host: 'splunk.example.com',
                                        port: 8088,
                                        enabled: true,
                                        connection_string: 'https://splunk.example.com:8088',
                                        access_token: 'test_token',
                                        destination_safe?: true,
                                        endpoint_path: nil) }
  let(:scan) { instance_double(Scan, output_server: output_server) }
  let(:target) { instance_double(Target, name: 'test-target', model: 'gpt-4', model_type: 'openai') }
  let(:report) { instance_double(Report, scan: scan, target: target, uuid: 'test-uuid') }
  let(:service) { OutputServers::Splunk.new(report) }

  before do
    @http_client = instance_double(Net::HTTP)
    @http_request = instance_double(Net::HTTP::Post)
    @http_response = instance_double(Net::HTTPResponse)

    allow(Net::HTTP).to receive(:new).and_return(@http_client)
    allow(Net::HTTP::Post).to receive(:new).and_return(@http_request)
    allow(@http_client).to receive(:use_ssl=)
    allow(@http_client).to receive(:verify_mode=)
    allow(@http_request).to receive(:[]=)
    allow(@http_request).to receive(:body=)
    allow(@http_request).to receive(:content_type=)
    allow(@http_request).to receive(:inspect).and_return('POST request')
    allow(@http_response).to receive(:code).and_return('200')
    allow(@http_response).to receive(:message).and_return('OK')
    allow(@http_response).to receive(:body).and_return('{"text":"Success"}')

    allow_any_instance_of(OutputServers::Splunk).to receive(:prepare_data).and_return({ event: 'test event' })
    allow_any_instance_of(OutputServers::Splunk).to receive(:handle_response)
    allow_any_instance_of(OutputServers::Splunk).to receive(:endpoint_url).and_return('https://splunk.example.com:8088/services/collector/event')
    allow_any_instance_of(OutputServers::Splunk).to receive(:setup_headers)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
  end

  describe '#call' do
    it 'makes a successful request to Splunk' do
      allow(@http_client).to receive(:request).and_return(@http_response)
      allow(URI).to receive(:parse).and_call_original
      allow_any_instance_of(OutputServers::Splunk).to receive(:handle_response) do |instance, response, request|
        Rails.logger.info "Successfully sent report data to Splunk"
      end

      expect(@http_client).to receive(:request)
      expect(Rails.logger).to receive(:info).with("Successfully sent report data to Splunk")

      service.call
    end

    context 'when the destination fails the SSRF recheck' do
      let(:unsafe_output_server) do
        instance_double(OutputServer, server_type: 'splunk', protocol: 'https',
                        host: '169.254.169.254', port: 8088, enabled: true,
                        connection_string: 'https://169.254.169.254:8088', access_token: 'x',
                        destination_safe?: false, endpoint_path: nil)
      end
      let(:unsafe_scan) { instance_double(Scan, output_server: unsafe_output_server) }
      let(:unsafe_report) { instance_double(Report, scan: unsafe_scan, target: target, uuid: 'test-uuid') }
      let(:unsafe_service) { OutputServers::Splunk.new(unsafe_report) }

      it 'aborts the send (no HTTP request) and logs the recheck failure' do
        allow(Rails.logger).to receive(:error)
        expect(@http_client).not_to receive(:request)

        unsafe_service.call

        expect(Rails.logger).to have_received(:error).with(/failed the SSRF recheck/)
      end
    end

    context 'when output_server is nil' do
      let(:nil_scan) { instance_double(Scan, output_server: nil) }
      let(:nil_report) { instance_double(Report, scan: nil_scan, target: target, uuid: 'test-uuid') }
      let(:nil_service) { OutputServers::Splunk.new(nil_report) }

      it 'returns early without making an HTTP request' do
        expect(@http_client).not_to receive(:request)
        nil_service.call
      end
    end

    context 'when output_server is disabled' do
      let(:disabled_output_server) { instance_double(OutputServer, enabled: false, server_type: 'splunk') }
      let(:disabled_scan) { instance_double(Scan, output_server: disabled_output_server) }
      let(:disabled_report) { instance_double(Report, scan: disabled_scan, target: target, uuid: 'test-uuid') }
      let(:disabled_service) { OutputServers::Splunk.new(disabled_report) }

      it 'returns early without making an HTTP request' do
        expect(@http_client).not_to receive(:request)
        disabled_service.call
      end
    end

    context 'when output_server is not of type splunk' do
      let(:wrong_type_output_server) { instance_double(OutputServer, enabled: true, server_type: 'rsyslog') }
      let(:wrong_type_scan) { instance_double(Scan, output_server: wrong_type_output_server) }
      let(:wrong_type_report) { instance_double(Report, scan: wrong_type_scan, target: target, uuid: 'test-uuid') }
      let(:wrong_type_service) { OutputServers::Splunk.new(wrong_type_report) }

      it 'returns early without making an HTTP request' do
        expect(@http_client).not_to receive(:request)
        wrong_type_service.call
      end
    end

    context 'when an error occurs' do
      it 'logs the error' do
        mock_request = double('request')
        allow(mock_request).to receive(:inspect).and_return('Mock request')
        allow(mock_request).to receive(:body).and_return('{"mock": "body"}')
        allow(mock_request).to receive(:body=)
        allow(mock_request).to receive(:content_type=)
        allow(Net::HTTP::Post).to receive(:new).and_return(mock_request)

        mock_uri = double('URI')
        allow(mock_uri).to receive(:request_uri).and_return('/services/collector/event')
        allow(mock_uri).to receive(:inspect).and_return('https://splunk.example.com:8088/services/collector/event')
        allow(mock_uri).to receive(:host).and_return('splunk.example.com')
        allow(mock_uri).to receive(:port).and_return(8088)
        allow(URI).to receive(:parse).and_return(mock_uri)

        allow(@http_client).to receive(:request).and_raise(StandardError.new('Connection failed'))

        expect(Rails.logger).to receive(:error).with(/Failed to send data to Splunk/).at_least(:once)
        expect(Rails.logger).to receive(:error).with(/Request: Mock request/).at_least(:once)

        service.call
      end
    end
  end
end
