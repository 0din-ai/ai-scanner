module OutputServers
  class Rsyslog
    # SECURITY: TLS cert/key/CA paths come from tenant-controlled additional_settings.
    # Only honor paths inside an operator-configured allowlist directory (SIEM_CERT_DIR)
    # so a tenant cannot read arbitrary files (e.g. /etc/passwd, config/master.key).
    ALLOWED_CERT_DIR = ENV["SIEM_CERT_DIR"].presence

    attr_reader :report

    def initialize(report)
      @report = report
    end

    def call
      return unless output_server
      return unless output_server.enabled
      return unless output_server.server_type == "rsyslog"

      unless output_server.destination_safe?
        Rails.logger.error("[rsyslog] aborting send for report #{report&.uuid}: host #{output_server.host} failed the SSRF recheck")
        return
      end

      begin
        case output_server.protocol
        when "udp"
          send_via_udp
        when "tcp"
          send_via_tcp
        when "tls"
          send_via_tls
        when "http", "https"
          send_via_http
        else
          Rails.logger.error "Unsupported protocol for RSyslog: #{output_server.protocol}"
        end
      rescue => e
        Rails.logger.error "Failed to send data to RSyslog: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    private

    def output_server
      report.scan.output_server
    end

    # Returns an absolute path ONLY if it resides inside the allowlisted
    # SIEM_CERT_DIR and the file exists; otherwise nil (path rejected/logged).
    # Prevents tenant-supplied additional_settings from reading arbitrary files.
    def safe_cert_path(path)
      return nil if path.blank?

      if ALLOWED_CERT_DIR.blank?
        Rails.logger.error("[rsyslog] TLS cert path ignored: SIEM_CERT_DIR is not configured")
        return nil
      end

      base = File.expand_path(ALLOWED_CERT_DIR)
      expanded = File.expand_path(path, base)
      unless expanded.start_with?(base + File::SEPARATOR) && File.file?(expanded)
        Rails.logger.error("[rsyslog] TLS cert path rejected (outside #{ALLOWED_CERT_DIR}): #{path}")
        return nil
      end

      expanded
    end

    # Abort a TLS send (return without connecting) when a configured cert/CA path is
    # rejected, so we never ship report data without the cert/verification the
    # operator explicitly configured.
    def abort_tls_send(reason)
      Rails.logger.error("[rsyslog] aborting TLS send for #{report.uuid}: #{reason}")
      nil
    end

    def send_via_udp
      socket = UDPSocket.new
      message = format_syslog_message

      begin
        socket.send(message, 0, output_server.host, output_server.port || 514)
        Rails.logger.info "Successfully sent report data to RSyslog (UDP) server: #{report.uuid}"
      rescue => e
        Rails.logger.error "Failed to send data to RSyslog via UDP: #{e.message}"
      ensure
        socket.close
      end
    end

    def send_via_tcp
      socket = TCPSocket.new(output_server.host, output_server.port || 514)
      message = format_syslog_message

      begin
        socket.puts(message)
        Rails.logger.info "Successfully sent report data to RSyslog (TCP) server: #{report.uuid}"
      rescue => e
        Rails.logger.error "Failed to send data to RSyslog via TCP: #{e.message}"
      ensure
        socket.close
      end
    end

    def send_via_tls
      context = OpenSSL::SSL::SSLContext.new

      # Apply additional TLS settings if available
      if output_server.additional_settings.present?
        begin
          settings = JSON.parse(output_server.additional_settings)

          # Client certificates (paths constrained to SIEM_CERT_DIR). If the operator
          # configured a cert/key but the path is rejected, ABORT — do not connect
          # without the client cert they required.
          if settings["tls_cert_file"].present? || settings["tls_key_file"].present?
            cert_path = safe_cert_path(settings["tls_cert_file"])
            key_path = safe_cert_path(settings["tls_key_file"])
            return abort_tls_send("client certificate path not allowed (set SIEM_CERT_DIR)") unless cert_path && key_path

            context.cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
            context.key = OpenSSL::PKey::RSA.new(File.read(key_path))
          end

          # CA certificate (path constrained to SIEM_CERT_DIR). If configured but
          # rejected, ABORT rather than silently downgrading to VERIFY_NONE — sending
          # report data without the requested server verification is a MITM risk.
          if settings["ca_file"].present?
            ca_path = safe_cert_path(settings["ca_file"])
            return abort_tls_send("CA certificate path not allowed (set SIEM_CERT_DIR)") unless ca_path

            context.ca_file = ca_path
            context.verify_mode = OpenSSL::SSL::VERIFY_PEER
          end
        rescue JSON::ParserError => e
          Rails.logger.error "Invalid additional_settings JSON: #{e.message}"
        end
      end

      tcp_socket = TCPSocket.new(output_server.host, output_server.port || 6514)
      ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, context)
      ssl_socket.connect

      message = format_syslog_message

      begin
        ssl_socket.puts(message)
        Rails.logger.info "Successfully sent report data to RSyslog (TLS) server: #{report.uuid}"
      rescue => e
        Rails.logger.error "Failed to send data to RSyslog via TLS: #{e.message}"
      ensure
        ssl_socket.close
        tcp_socket.close
      end
    end

    def send_via_http
      require "net/http"

      uri = URI.parse(output_server.connection_string)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (output_server.protocol == "https")

      request = Net::HTTP::Post.new(uri.request_uri)
      setup_headers(request)
      request.body = prepare_data.to_json

      begin
        response = http.request(request)
        if response.code.to_i >= 200 && response.code.to_i < 300
          Rails.logger.info "Successfully sent report data to RSyslog (HTTP) server: #{report.uuid}"
        else
          Rails.logger.error "Failed to send data to RSyslog. Status: #{response.code}, Body: #{response.body}"
        end
      rescue => e
        Rails.logger.error "Failed to send data to RSyslog via HTTP: #{e.message}"
      end
    end

    def setup_headers(request)
      request.content_type = "application/json"

      case output_server.authentication_method
      when :token
        request["Authorization"] = "Bearer #{output_server.access_token}"
      when :api_key
        request["X-API-Key"] = output_server.api_key
      when :basic
        request.basic_auth(output_server.username, output_server.password)
      end

      if output_server.additional_settings.present?
        begin
          settings = JSON.parse(output_server.additional_settings)
          if settings["headers"].is_a?(Hash)
            settings["headers"].each do |key, value|
              request[key] = value
            end
          end
        rescue JSON::ParserError => e
          Rails.logger.error "Invalid additional_settings JSON: #{e.message}"
        end
      end
    end

    def format_syslog_message
      msg = SyslogProtocol::Packet.new

      # Set standard syslog fields
      msg.hostname = BrandConfig.host_url&.gsub(%r{https?://}, "") || "scanner.local"
      msg.facility = "local0"
      msg.severity = "info"
      msg.tag = "scanner_app"

      message_data = {
        report_id: report.id,
        report_uuid: report.uuid,
        report_name: report.name,
        report_status: report.status,
        scan_id: report.scan_id,
        scan_name: report.scan&.name,
        target_id: report.target_id,
        target_name: report.target&.name,
        target_model: report.target&.model,
        target_model_type: report.target&.model_type,
        created_at: report.created_at,
        updated_at: report.updated_at,
        probe_results_count: report.probe_results.count,
        detector_stats: report.detector_results_as_hash
      }

      msg.content = message_data.to_json
      msg.to_s
    end

    def prepare_data
      {
        timestamp: Time.now.strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
        hostname: BrandConfig.host_url&.gsub(%r{https?://}, "") || "scanner.local",
        source: "scanner_app",
        event: {
          report_id: report.id,
          report_uuid: report.uuid,
          report_name: report.name,
          report_status: report.status,
          scan_id: report.scan_id,
          scan_name: report.scan.name,
          target_id: report.target_id,
          target_name: report.target.name,
          target_model: report.target.model,
          target_model_type: report.target.model_type,
          created_at: report.created_at,
          updated_at: report.updated_at,
          probe_results_count: report.probe_results.count,
          detector_stats: report.detector_results_as_hash
        }
      }
    end
  end
end
