require 'rails_helper'

RSpec.describe OutputServers::Rsyslog do
  let(:output_server) { instance_double(OutputServer, server_type: 'rsyslog', protocol: 'udp', host: 'syslog.example.com', port: 514, enabled: true, destination_safe?: true) }
  let(:scan) { instance_double(Scan, output_server: output_server) }
  let(:report) { instance_double(Report, scan: scan, uuid: 'test-uuid') }
  let(:service) { OutputServers::Rsyslog.new(report) }

  describe '#call' do
    context 'when using UDP protocol' do
      let(:udp_socket) { instance_double(UDPSocket) }

      before do
        allow(UDPSocket).to receive(:new).and_return(udp_socket)
        allow(udp_socket).to receive(:send)
        allow(udp_socket).to receive(:close)
        allow(service).to receive(:format_syslog_message).and_return('test syslog message')
      end

      it 'sends data via UDP socket' do
        expect(udp_socket).to receive(:send).with('test syslog message', 0, 'syslog.example.com', 514)
        service.call
      end

      it 'closes the socket after sending' do
        expect(udp_socket).to receive(:close)
        service.call
      end

      context 'when an error occurs' do
        it 'logs the error and closes the socket' do
          allow(udp_socket).to receive(:send).and_raise(StandardError.new('Socket error'))
          expect(Rails.logger).to receive(:error).with(/Failed to send data to RSyslog via UDP/)
          expect(udp_socket).to receive(:close)
          service.call
        end
      end
    end

    context 'when using TCP protocol' do
      let(:tcp_output_server) { instance_double(OutputServer, server_type: 'rsyslog', protocol: 'tcp', host: 'syslog.example.com', port: 514, enabled: true, destination_safe?: true) }
      let(:tcp_scan) { instance_double(Scan, output_server: tcp_output_server) }
      let(:tcp_report) { instance_double(Report, scan: tcp_scan, uuid: 'test-uuid') }
      let(:tcp_service) { OutputServers::Rsyslog.new(tcp_report) }

      before do
        allow(tcp_service).to receive(:send_via_tcp)
      end

      it 'calls send_via_tcp' do
        expect(tcp_service).to receive(:send_via_tcp)
        tcp_service.call
      end
    end

    context 'when the destination fails the SSRF recheck' do
      let(:unsafe_output_server) { instance_double(OutputServer, server_type: 'rsyslog', protocol: 'udp', host: '169.254.169.254', port: 514, enabled: true, destination_safe?: false) }
      let(:unsafe_scan) { instance_double(Scan, output_server: unsafe_output_server) }
      let(:unsafe_report) { instance_double(Report, scan: unsafe_scan, uuid: 'test-uuid') }
      let(:unsafe_service) { OutputServers::Rsyslog.new(unsafe_report) }

      it 'aborts without opening a socket and logs the recheck failure' do
        allow(Rails.logger).to receive(:error)
        expect(UDPSocket).not_to receive(:new)

        unsafe_service.call

        expect(Rails.logger).to have_received(:error).with(/failed the SSRF recheck/)
      end
    end

    context 'when output_server is nil' do
      let(:nil_scan) { instance_double(Scan, output_server: nil) }
      let(:nil_report) { instance_double(Report, scan: nil_scan, uuid: 'test-uuid') }
      let(:nil_service) { OutputServers::Rsyslog.new(nil_report) }

      it 'returns without sending data' do
        expect(UDPSocket).not_to receive(:new)
        nil_service.call
      end
    end

    context 'when output_server is not enabled' do
      let(:disabled_output_server) { instance_double(OutputServer, server_type: 'rsyslog', protocol: 'udp', host: 'syslog.example.com', port: 514, enabled: false) }
      let(:disabled_scan) { instance_double(Scan, output_server: disabled_output_server) }
      let(:disabled_report) { instance_double(Report, scan: disabled_scan, uuid: 'test-uuid') }
      let(:disabled_service) { OutputServers::Rsyslog.new(disabled_report) }

      it 'returns without sending data' do
        expect(UDPSocket).not_to receive(:new)
        disabled_service.call
      end
    end

    context 'when output_server type is not rsyslog' do
      let(:wrong_type_output_server) { instance_double(OutputServer, server_type: 'splunk', protocol: 'udp', host: 'syslog.example.com', port: 514, enabled: true) }
      let(:wrong_type_scan) { instance_double(Scan, output_server: wrong_type_output_server) }
      let(:wrong_type_report) { instance_double(Report, scan: wrong_type_scan, uuid: 'test-uuid') }
      let(:wrong_type_service) { OutputServers::Rsyslog.new(wrong_type_report) }

      it 'returns without sending data' do
        expect(UDPSocket).not_to receive(:new)
        wrong_type_service.call
      end
    end
  end

  describe 'TLS cert-path allowlist (SIEM_CERT_DIR)' do
    let(:svc) { OutputServers::Rsyslog.allocate }

    it 'rejects cert paths outside SIEM_CERT_DIR (and traversal)' do
      Dir.mktmpdir do |dir|
        stub_const('OutputServers::Rsyslog::ALLOWED_CERT_DIR', dir)
        allow(Rails.logger).to receive(:error)

        expect(svc.send(:safe_cert_path, '/etc/passwd')).to be_nil
        expect(svc.send(:safe_cert_path, '../../etc/passwd')).to be_nil

        File.write(File.join(dir, 'client.pem'), 'x')
        expect(svc.send(:safe_cert_path, 'client.pem')).to eq(File.join(dir, 'client.pem'))
      end
    end

    it 'ignores all cert paths when SIEM_CERT_DIR is unset' do
      stub_const('OutputServers::Rsyslog::ALLOWED_CERT_DIR', nil)
      allow(Rails.logger).to receive(:error)
      expect(svc.send(:safe_cert_path, '/etc/passwd')).to be_nil
    end

    it 'aborts the TLS send (no socket) when a configured CA path is rejected (no VERIFY_NONE downgrade)' do
      stub_const('OutputServers::Rsyslog::ALLOWED_CERT_DIR', nil)
      os = instance_double(OutputServer, server_type: 'rsyslog', protocol: 'tls', host: '8.8.8.8',
                           port: 6514, enabled: true, destination_safe?: true,
                           additional_settings: { ca_file: '/etc/ssl/ca.pem' }.to_json)
      report = instance_double(Report, scan: instance_double(Scan, output_server: os), uuid: 'tls-uuid')
      allow(Rails.logger).to receive(:error)
      expect(TCPSocket).not_to receive(:new)

      OutputServers::Rsyslog.new(report).call

      expect(Rails.logger).to have_received(:error).with(/aborting TLS send/)
    end
  end
end
