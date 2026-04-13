# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "socket"

module OutputServers
  # Tests connectivity to a configured output server by sending a synthetic test event.
  # Used by the "Test Integration" button on the integrations page.
  class ConnectionTest
    attr_reader :output_server

    def initialize(output_server)
      @output_server = output_server
    end

    def call
      return { success: false, message: "Integration is not enabled" } unless output_server.enabled?

      safety = validate_host_safety
      return safety unless safety.nil?

      case output_server.server_type
      when "splunk"
        test_splunk
      when "rsyslog"
        test_rsyslog
      else
        { success: false, message: "Unknown server type: #{output_server.server_type}" }
      end
    rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout => e
      { success: false, message: "Connection failed: #{e.message}" }
    rescue OpenSSL::SSL::SSLError => e
      { success: false, message: "SSL error: #{e.message}" }
    rescue => e
      { success: false, message: "Unexpected error: #{e.class} - #{e.message}" }
    end

    private

    def validate_host_safety
      result = UrlSafetyValidator.safe_host?(output_server.host, allow_localhost: UrlSafetyValidator.allow_localhost?)
      return { success: false, message: "Connection blocked: #{result.error}" } unless result.safe?

      @pinned_ip = result.resolved_ips&.first

      url = output_server.connection_string
      begin
        parsed_host = URI.parse(url).host
      rescue URI::InvalidURIError
        return { success: false, message: "Connection blocked: constructed URL is invalid" }
      end
      if parsed_host && parsed_host != output_server.host
        url_result = UrlSafetyValidator.safe_host?(parsed_host, allow_localhost: UrlSafetyValidator.allow_localhost?)
        return { success: false, message: "Connection blocked: constructed URL resolves to a different host" } unless url_result.safe?
      end

      nil
    end

    def connection_host
      @pinned_ip || output_server.host
    end

    def test_splunk
      base_url = output_server.connection_string
      base_url += "/services/collector/event" unless output_server.endpoint_path.present?
      uri = URI.parse(base_url)

      http = Net::HTTP.new(connection_host, uri.port)
      http.use_ssl = (output_server.protocol == "https")
      http.open_timeout = 10
      http.read_timeout = 10

      request = Net::HTTP::Post.new(uri.request_uri)
      request.content_type = "application/json"
      setup_auth_headers(request)

      request.body = {
        time: Time.now.to_i,
        host: BrandConfig.host_url&.gsub(%r{https?://}, "") || "scanner.local",
        source: "scanner_app",
        sourcetype: "scanner_test",
        event: {
          test: true,
          message: "Scanner integration test",
          timestamp: Time.current.iso8601
        }
      }.to_json

      response = http.request(request)

      if response.code.to_i >= 200 && response.code.to_i < 300
        { success: true, message: "Successfully connected to Splunk (HTTP #{response.code})" }
      else
        { success: false, message: "Splunk returned HTTP #{response.code}: #{response.body&.truncate(200)}" }
      end
    end

    def test_rsyslog
      case output_server.protocol
      when "udp"
        test_rsyslog_udp
      when "tcp"
        test_rsyslog_tcp
      when "tls"
        test_rsyslog_tls
      when "http", "https"
        test_rsyslog_http
      else
        { success: false, message: "Unknown protocol: #{output_server.protocol}" }
      end
    end

    def test_rsyslog_udp
      socket = UDPSocket.new
      socket.send(test_syslog_message, 0, connection_host, output_server.port || 514)
      { success: true, message: "Successfully sent test message via UDP to #{output_server.host}:#{output_server.port || 514}" }
    ensure
      safe_close(socket)
    end

    def test_rsyslog_tcp
      socket = TCPSocket.new(connection_host, output_server.port || 514)
      socket.puts(test_syslog_message)
      { success: true, message: "Successfully connected via TCP to #{output_server.host}:#{output_server.port || 514}" }
    ensure
      safe_close(socket)
    end

    def test_rsyslog_tls
      tcp = TCPSocket.new(connection_host, output_server.port || 6514)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
      ssl.hostname = output_server.host
      ssl.connect
      ssl.puts(test_syslog_message)
      { success: true, message: "Successfully connected via TLS to #{output_server.host}:#{output_server.port || 6514}" }
    ensure
      safe_close(ssl)
      safe_close(tcp)
    end

    def test_rsyslog_http
      uri = URI.parse(output_server.connection_string)
      http = Net::HTTP.new(connection_host, uri.port)
      http.use_ssl = (output_server.protocol == "https")
      http.open_timeout = 10
      http.read_timeout = 10

      request = Net::HTTP::Post.new(uri.request_uri)
      request.content_type = "application/json"
      setup_auth_headers(request)

      request.body = {
        timestamp: Time.current.iso8601,
        hostname: BrandConfig.host_url&.gsub(%r{https?://}, "") || "scanner.local",
        source: "scanner_app",
        event: { test: true, message: "Scanner integration test" }
      }.to_json

      response = http.request(request)

      if response.code.to_i >= 200 && response.code.to_i < 300
        { success: true, message: "Successfully connected via HTTP (#{response.code})" }
      else
        { success: false, message: "Rsyslog HTTP returned #{response.code}: #{response.body&.truncate(200)}" }
      end
    end

    def setup_auth_headers(request)
      case output_server.authentication_method
      when :token
        request["Authorization"] = "Splunk #{output_server.access_token}"
      when :api_key
        request["Authorization"] = "Bearer #{output_server.api_key}"
      when :basic
        request.basic_auth(output_server.username, output_server.password)
      end
    end

    def safe_close(io)
      io&.close
    rescue IOError, Errno::EBADF
      # already closed or invalid descriptor
    end

    def test_syslog_message
      "<14>#{Time.now.strftime('%b %d %H:%M:%S')} scanner scanner_app: Scanner integration test - #{Time.current.iso8601}"
    end
  end
end
