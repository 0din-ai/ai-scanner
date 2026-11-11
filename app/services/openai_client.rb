require "openai"
require "json"

class OpenaiClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class RateLimitError < Error; end
  class InvalidResponseError < Error; end

  DEFAULT_TIMEOUT = 120 # seconds
  DEFAULT_MODEL = "gpt-5.6-sol"

  def initialize(api_key = nil, base_url = nil)
    @api_key = api_key || fetch_api_key_from_db
    @base_url = base_url || ENV["OPENAI_API_URL"]

    raise Error, "OpenAI API key is required" unless @api_key

    @client = setup_client
  end

  # Chat completion - main method for conversational interactions
  def chat(model: DEFAULT_MODEL, messages:, temperature: 0.7, format: nil, timeout: DEFAULT_TIMEOUT)
    parameters = {
      model: model,
      messages: prepare_messages(messages)
    }

    # GPT-5 doesn't support temperature parameter
    parameters[:temperature] = temperature unless model.start_with?("gpt-5")

    # Add response format for JSON outputs
    if format == "json" || format == :json
      parameters[:response_format] = { type: "json_object" }
      # Ensure the prompt mentions JSON format
      if parameters[:messages].last[:role] == "user"
        parameters[:messages].last[:content] += "\n\nRespond with valid JSON format."
      end
    end

    begin
      response = @client.chat(parameters: parameters)

      if response.dig("error")
        handle_api_error(response["error"])
      end

      content = response.dig("choices", 0, "message", "content")

      if format == "json" || format == :json
        parse_json_response(content)
      else
        content
      end
    rescue Faraday::TimeoutError => e
      raise ConnectionError, "Request timeout after #{timeout} seconds"
    rescue Faraday::ConnectionFailed => e
      raise ConnectionError, "Failed to connect to OpenAI API: #{e.message}"
    rescue StandardError => e
      handle_client_error(e)
    end
  end

  # Structured output using function calling
  def extract_structured_data(prompt:, schema:, model: DEFAULT_MODEL, system: nil, timeout: DEFAULT_TIMEOUT)
    messages = []
    messages << { role: "system", content: system } if system
    messages << { role: "user", content: prompt }

    function = {
      name: "extract_data",
      description: "Extract structured data from the input",
      parameters: schema
    }

    parameters = {
      model: model,
      messages: messages,
      **(model == DEFAULT_MODEL ? { reasoning_effort: "none" } : {}),
      functions: [ function ],
      function_call: { name: "extract_data" }
    }

    # GPT-5 doesn't support temperature parameter
    parameters[:temperature] = 0.1 unless model.start_with?("gpt-5") # Lower temperature for structured extraction

    begin
      response = @client.chat(parameters: parameters)

      if response.dig("error")
        handle_api_error(response["error"])
      end

      function_call = response.dig("choices", 0, "message", "function_call")

      if function_call && function_call["arguments"]
        JSON.parse(function_call["arguments"])
      else
        raise InvalidResponseError, "No structured data extracted"
      end
    rescue JSON::ParserError => e
      raise InvalidResponseError, "Invalid JSON in function response: #{e.message}"
    rescue StandardError => e
      handle_client_error(e)
    end
  end

  private

  def setup_client
    config = {
      access_token: @api_key,
      request_timeout: DEFAULT_TIMEOUT
    }

    # Support for Azure OpenAI or custom endpoints
    if @base_url
      config[:uri_base] = @base_url
    end

    OpenAI::Client.new(config)
  end

  def prepare_messages(messages)
    # Convert messages to OpenAI format if needed
    if messages.is_a?(Array)
      messages.map do |msg|
        if msg.is_a?(Hash)
          {
            role: msg[:role] || msg["role"],
            content: msg[:content] || msg["content"]
          }
        else
          msg
        end
      end
    else
      [ { role: "user", content: messages.to_s } ]
    end
  end

  def parse_json_response(response_text)
    return nil if response_text.nil? || response_text.empty?

    # Try to extract JSON from the response
    # Sometimes models include extra text around JSON
    json_match = response_text.match(/\{.*\}/m) || response_text.match(/\[.*\]/m)

    if json_match
      JSON.parse(json_match[0])
    else
      # Try parsing the whole response
      JSON.parse(response_text)
    end
  rescue JSON::ParserError => e
    Rails.logger.error "Failed to parse JSON response: #{response_text}"
    raise InvalidResponseError, "Invalid JSON in response: #{e.message}"
  end

  def handle_api_error(error)
    error_message = error["message"] || error.to_s
    error_type = error["type"] || "unknown"

    case error_type
    when "rate_limit_exceeded"
      raise RateLimitError, "Rate limit exceeded: #{error_message}"
    when "invalid_request_error"
      raise Error, "Invalid request: #{error_message}"
    when "authentication_error"
      raise Error, "Authentication failed: #{error_message}"
    else
      raise Error, "OpenAI API error: #{error_message}"
    end
  end

  def handle_client_error(error)
    # Check for rate limit errors first
    if error.message&.match?(/rate/i)
      raise RateLimitError, error.message
    end

    case error
    when OpenAI::Error
      raise Error, "OpenAI client error: #{error.message}"
    else
      raise Error, "Unexpected error: #{error.message}"
    end
  end

  def fetch_api_key_from_db
    EnvironmentVariable.global.find_by(env_name: "OPENAI_API_KEY")&.env_value
  end
end
