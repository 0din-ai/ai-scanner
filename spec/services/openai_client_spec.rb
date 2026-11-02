require "rails_helper"

RSpec.describe OpenaiClient do
  let(:api_key) { "test-api-key" }
  let(:client) { described_class.new(api_key) }
  let(:mock_openai_client) { instance_double(OpenAI::Client) }

  before do
    allow(OpenAI::Client).to receive(:new).and_return(mock_openai_client)
  end

  describe "#initialize" do
    context "without API key" do
      it "raises an error when no API key is provided" do
        allow(EnvironmentVariable).to receive_message_chain(:global, :find_by).and_return(nil)

        expect { described_class.new(nil) }.to raise_error(OpenaiClient::Error, "OpenAI API key is required")
      end
    end

    context "with API key from environment" do
      it "initializes successfully" do
        allow(EnvironmentVariable).to receive_message_chain(:global, :find_by).and_return(
          double(resolved_value: "db-api-key")
        )

        expect { described_class.new }.not_to raise_error
      end
    end
  end

  describe "#fetch_api_key_from_db with tenant context" do
    context "without tenant context" do
      it "still retrieves the API key" do
        env_var = double(resolved_value: "db-api-key")
        allow(EnvironmentVariable).to receive_message_chain(:global, :find_by).and_return(env_var)

        ActsAsTenant.without_tenant do
          client = described_class.new
          expect(client).to be_a(described_class)
        end
      end
    end

    context "with tenant context" do
      let(:company) { create(:company) }

      it "retrieves the API key scoped to the tenant" do
        ActsAsTenant.with_tenant(company) do
          create(:environment_variable, target: nil, env_name: "OPENAI_API_KEY", env_value: "tenant-key")
        end

        ActsAsTenant.with_tenant(company) do
          client = described_class.new
          expect(client).to be_a(described_class)
        end
      end

      it "resolves a development reference when constructing the provider client" do
        previous = ENV["OPENROUTER_API_KEY"]
        ENV["OPENROUTER_API_KEY"] = "process-canary"
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
        env_var = ActsAsTenant.with_tenant(company) do
          create(:environment_variable, target: nil, env_name: "OPENAI_API_KEY",
                 env_value: "env:OPENROUTER_API_KEY", company: company)
        end
        expect(OpenAI::Client).to receive(:new)
          .with(hash_including(access_token: "process-canary"))
          .and_return(mock_openai_client)

        ActsAsTenant.with_tenant(company) { described_class.new }

        expect(ActsAsTenant.with_tenant(company) { env_var.reload.env_value }).to eq("env:OPENROUTER_API_KEY")
      ensure
        previous.nil? ? ENV.delete("OPENROUTER_API_KEY") : ENV["OPENROUTER_API_KEY"] = previous
      end
    end
  end

  describe "#chat" do
    let(:messages) { [ { role: "user", content: "Hello" } ] }
    let(:successful_response) do
      {
        "choices" => [
          {
            "message" => {
              "content" => "Hello! How can I help you?"
            }
          }
        ]
      }
    end

    context "with successful response" do
      before do
        allow(mock_openai_client).to receive(:chat).and_return(successful_response)
      end

      it "returns the response content" do
        result = client.chat(messages: messages)
        expect(result).to eq("Hello! How can I help you?")
      end

      it "supports JSON format" do
        json_response = successful_response.dup
        json_response["choices"][0]["message"]["content"] = '{"key": "value"}'
        allow(mock_openai_client).to receive(:chat).and_return(json_response)

        result = client.chat(messages: messages, format: "json")
        expect(result).to eq({ "key" => "value" })
      end
    end

    context "with API error" do
      let(:error_response) do
        {
          "error" => {
            "message" => "Rate limit exceeded",
            "type" => "rate_limit_exceeded"
          }
        }
      end

      before do
        allow(mock_openai_client).to receive(:chat).and_return(error_response)
      end

      it "raises RateLimitError for rate limit errors" do
        expect { client.chat(messages: messages) }.to raise_error(OpenaiClient::RateLimitError)
      end
    end

    context "with connection timeout" do
      before do
        allow(mock_openai_client).to receive(:chat).and_raise(Faraday::TimeoutError)
      end

      it "raises ConnectionError" do
        expect { client.chat(messages: messages) }.to raise_error(OpenaiClient::ConnectionError, /timeout/)
      end
    end
  end

  describe "#extract_structured_data" do
    let(:prompt) { "Extract information from this text: John is 30 years old" }
    let(:schema) do
      {
        type: "object",
        properties: {
          name: { type: "string" },
          age: { type: "integer" }
        }
      }
    end
    let(:successful_response) do
      {
        "choices" => [
          {
            "message" => {
              "function_call" => {
                "name" => "extract_data",
                "arguments" => '{"name": "John", "age": 30}'
              }
            }
          }
        ]
      }
    end

    before do
      allow(mock_openai_client).to receive(:chat).and_return(successful_response)
    end

    it "extracts structured data using function calling" do
      result = client.extract_structured_data(prompt: prompt, schema: schema)
      expect(result).to eq({ "name" => "John", "age" => 30 })
    end

    context "with invalid JSON in function response" do
      let(:invalid_response) do
        {
          "choices" => [
            {
              "message" => {
                "function_call" => {
                  "name" => "extract_data",
                  "arguments" => 'invalid json'
                }
              }
            }
          ]
        }
      end

      before do
        allow(mock_openai_client).to receive(:chat).and_return(invalid_response)
      end

      it "raises InvalidResponseError" do
        expect { client.extract_structured_data(prompt: prompt, schema: schema) }
          .to raise_error(OpenaiClient::InvalidResponseError, /Invalid JSON/)
      end
    end
  end
end
