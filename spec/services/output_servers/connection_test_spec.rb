# frozen_string_literal: true

require "rails_helper"

RSpec.describe OutputServers::ConnectionTest do
  describe "SSRF protection" do
    context "in production (localhost not allowed)" do
      before do
        allow(Rails.env).to receive(:development?).and_return(false)
        allow(Rails.env).to receive(:test?).and_return(false)
      end

      it "blocks connections to localhost" do
        server = build(:output_server, host: "127.0.0.1", enabled: true)
        result = described_class.new(server).call

        expect(result[:success]).to be false
        expect(result[:message]).to include("Connection blocked")
      end

      it "blocks connections to IPv6 loopback" do
        server = build(:output_server, host: "::1", enabled: true)
        result = described_class.new(server).call

        expect(result[:success]).to be false
        expect(result[:message]).to include("Connection blocked")
      end
    end

    it "blocks connections to private RFC1918 addresses" do
      %w[10.0.0.1 172.16.0.1 192.168.1.1].each do |ip|
        server = build(:output_server, host: ip, enabled: true)
        result = described_class.new(server).call

        expect(result[:success]).to be false
        expect(result[:message]).to include("Connection blocked"), "Expected #{ip} to be blocked"
      end
    end

    it "blocks connections to cloud metadata endpoint" do
      server = build(:output_server, host: "169.254.169.254", enabled: true)
      result = described_class.new(server).call

      expect(result[:success]).to be false
      expect(result[:message]).to include("Connection blocked")
    end

    it "blocks hostnames that resolve to internal IPs" do
      allow(UrlSafetyValidator).to receive(:resolve_addresses).with("evil.internal").and_return([ "10.0.0.1" ])
      server = build(:output_server, host: "evil.internal", enabled: true)
      result = described_class.new(server).call

      expect(result[:success]).to be false
      expect(result[:message]).to include("Connection blocked")
    end

    it "returns not-enabled message before SSRF check when disabled" do
      server = build(:output_server, host: "127.0.0.1", enabled: false)
      result = described_class.new(server).call

      expect(result[:success]).to be false
      expect(result[:message]).to include("not enabled")
    end

    it "blocks connections when endpoint_path redirects to a different host via @ in URI" do
      server = build(:output_server, host: "safe.example.com", endpoint_path: "@evil.com/ssrf", enabled: true)
      allow(UrlSafetyValidator).to receive(:safe_host?).and_call_original
      allow(UrlSafetyValidator).to receive(:resolve_addresses).with("safe.example.com").and_return([ "93.184.216.34" ])
      allow(UrlSafetyValidator).to receive(:resolve_addresses).with("evil.com").and_return([ "10.0.0.1" ])

      result = described_class.new(server).call

      expect(result[:success]).to be false
      expect(result[:message]).to include("Connection blocked")
    end

    it "blocks connections when endpoint_path makes constructed URL resolve to internal host" do
      server = build(:output_server, host: "safe.example.com", endpoint_path: "@169.254.169.254/metadata", enabled: true)
      allow(UrlSafetyValidator).to receive(:safe_host?).and_call_original
      allow(UrlSafetyValidator).to receive(:resolve_addresses).with("safe.example.com").and_return([ "93.184.216.34" ])

      result = described_class.new(server).call

      expect(result[:success]).to be false
      expect(result[:message]).to include("Connection blocked")
    end

    it "treats URI parse failure as unsafe instead of passing" do
      server = build(:output_server, host: "safe.example.com", enabled: true)
      allow(UrlSafetyValidator).to receive(:safe_host?).and_return(
        UrlSafetyValidator::Result.new("safe?": true, error: nil)
      )
      allow(server).to receive(:connection_string).and_return("http://[invalid uri")

      result = described_class.new(server).call

      expect(result[:success]).to be false
      expect(result[:message]).to include("Connection blocked")
      expect(result[:message]).to include("invalid")
    end
  end

  describe "TLS certificate verification" do
    let(:server) { build(:output_server, server_type: "rsyslog", protocol: "tls", host: "example.com", port: 6514, enabled: true) }
    let(:tcp_socket) { instance_double(TCPSocket) }
    let(:ssl_context) { instance_double(OpenSSL::SSL::SSLContext) }
    let(:ssl_socket) { instance_double(OpenSSL::SSL::SSLSocket) }
    let(:cert_store) { instance_double(OpenSSL::X509::Store) }

    before do
      allow(UrlSafetyValidator).to receive(:safe_host?).and_return(
        UrlSafetyValidator::Result.new("safe?": true, error: nil)
      )
      allow(TCPSocket).to receive(:new).and_return(tcp_socket)
      allow(OpenSSL::SSL::SSLContext).to receive(:new).and_return(ssl_context)
      allow(OpenSSL::X509::Store).to receive(:new).and_return(cert_store)
      allow(cert_store).to receive(:set_default_paths).and_return(cert_store)
      allow(ssl_context).to receive(:verify_mode=)
      allow(ssl_context).to receive(:cert_store=)
      allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(ssl_socket)
      allow(ssl_socket).to receive(:hostname=)
      allow(ssl_socket).to receive(:connect)
      allow(ssl_socket).to receive(:puts)
      allow(ssl_socket).to receive(:close)
      allow(tcp_socket).to receive(:close)
    end

    it "sets verify_mode to VERIFY_PEER" do
      described_class.new(server).call
      expect(ssl_context).to have_received(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)
    end

    it "sets the certificate store with default paths" do
      described_class.new(server).call
      expect(cert_store).to have_received(:set_default_paths)
    end

    it "sets SNI hostname" do
      described_class.new(server).call
      expect(ssl_socket).to have_received(:hostname=).with("example.com")
    end

    it "connects to the pinned IP from DNS resolution instead of re-resolving hostname" do
      allow(UrlSafetyValidator).to receive(:safe_host?).and_return(
        UrlSafetyValidator::Result.new("safe?": true, error: nil, resolved_ips: [ "93.184.216.34" ])
      )
      described_class.new(server).call
      expect(TCPSocket).to have_received(:new).with("93.184.216.34", 6514)
      expect(ssl_socket).to have_received(:hostname=).with("example.com")
    end
  end

  describe "DNS rebinding prevention" do
    it "pins resolved IP for Splunk HTTP connections" do
      server = build(:output_server, server_type: "splunk", host: "example.com", port: 8088, enabled: true)
      allow(UrlSafetyValidator).to receive(:safe_host?).and_return(
        UrlSafetyValidator::Result.new("safe?": true, error: nil, resolved_ips: [ "93.184.216.34" ])
      )

      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)

      response = instance_double(Net::HTTPResponse, code: "200", body: "OK")
      allow(http_double).to receive(:request).and_return(response)

      described_class.new(server).call
      expect(Net::HTTP).to have_received(:new).with("93.184.216.34", anything)
    end

    it "pins resolved IP for TCP syslog connections" do
      server = build(:output_server, server_type: "rsyslog", protocol: "tcp", host: "example.com", port: 514, enabled: true)
      allow(UrlSafetyValidator).to receive(:safe_host?).and_return(
        UrlSafetyValidator::Result.new("safe?": true, error: nil, resolved_ips: [ "93.184.216.34" ])
      )

      socket = instance_double(TCPSocket)
      allow(TCPSocket).to receive(:new).and_return(socket)
      allow(socket).to receive(:puts)
      allow(socket).to receive(:close)

      described_class.new(server).call
      expect(TCPSocket).to have_received(:new).with("93.184.216.34", 514)
    end

    it "pins resolved IP for UDP syslog connections" do
      server = build(:output_server, server_type: "rsyslog", protocol: "udp", host: "example.com", port: 514, enabled: true)
      allow(UrlSafetyValidator).to receive(:safe_host?).and_return(
        UrlSafetyValidator::Result.new("safe?": true, error: nil, resolved_ips: [ "93.184.216.34" ])
      )

      socket = instance_double(UDPSocket)
      allow(UDPSocket).to receive(:new).and_return(socket)
      allow(socket).to receive(:send)
      allow(socket).to receive(:close)

      described_class.new(server).call
      expect(socket).to have_received(:send).with(anything, 0, "93.184.216.34", 514)
    end
  end
end
