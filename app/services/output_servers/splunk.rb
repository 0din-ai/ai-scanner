require "net/http"
require "uri"
require "json"

module OutputServers
  class Splunk
    attr_reader :report

    def initialize(report)
      @report = report
    end

    def call
      return unless output_server
      return unless output_server.enabled
      return unless output_server.server_type == "splunk"

      unless output_server.destination_safe?
        Rails.logger.error("[Splunk] aborting send for report #{report&.uuid}: host #{output_server.host} failed the SSRF recheck")
        return
      end

      uri = URI.parse(endpoint_url)
      http = setup_http_connection(uri)

      request = Net::HTTP::Post.new(uri.request_uri)
      setup_headers(request)
      request.body = prepare_data.to_json

      begin
        response = http.request(request)
        handle_response(response, request)
      rescue => e
        Rails.logger.error "Failed to send data to Splunk: #{e.message}"
        Rails.logger.error "Request: #{request.inspect}"
        Rails.logger.error "Request Body: #{request.body}"
        Rails.logger.error "Request URI: #{uri.inspect}"
      end
    end

    private

    def output_server
      report.scan.output_server
    end

    def endpoint_url
      base_url = output_server.connection_string
      base_url += "/services/collector/event" unless output_server.endpoint_path.present?
      base_url
    end

    def setup_http_connection(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (output_server.protocol == "https")
      http
    end

    def setup_headers(request)
      request.content_type = "application/json"

      case output_server.authentication_method
      when :token
        request["Authorization"] = "Splunk #{output_server.access_token}"
      when :api_key
        request["Authorization"] = "Splunk #{output_server.api_key}"
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



    def prepare_data
      {
        time: Time.now.to_i,
        host: BrandConfig.host_url&.gsub(%r{https?://}, "") || "scanner.local",
        source: "scanner_app",
        sourcetype: "scan_report",
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

    def handle_response(response, request)
      if response.code.to_i >= 200 && response.code.to_i < 300
        Rails.logger.info "Successfully sent report data to Splunk: #{report.uuid}"
      else
        Rails.logger.error "Failed to send data to Splunk. Status: #{response.code}, Body: #{response.body}"
      end
    end
  end
end
