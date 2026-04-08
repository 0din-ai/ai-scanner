# frozen_string_literal: true

require "rails_helper"

RSpec.describe TokenEstimator do
  describe ".estimate_tokens" do
    it "returns 0 for nil text" do
      expect(described_class.estimate_tokens(nil)).to eq(0)
    end

    it "returns 0 for empty string" do
      expect(described_class.estimate_tokens("")).to eq(0)
    end

    it "counts tokens in simple text" do
      # "Hello world" typically tokenizes to 2 tokens
      result = described_class.estimate_tokens("Hello world")
      expect(result).to be > 0
      expect(result).to be_a(Integer)
    end

    it "counts tokens in longer text" do
      short_text = "Hello"
      long_text = "Hello, this is a much longer piece of text that should have more tokens."

      short_count = described_class.estimate_tokens(short_text)
      long_count = described_class.estimate_tokens(long_text)

      expect(long_count).to be > short_count
    end

    it "handles unicode text" do
      result = described_class.estimate_tokens("Hello 世界 🌍")
      expect(result).to be > 0
    end
  end

  describe ".estimate_from_attempt" do
    it "returns zeros for nil attempt" do
      result = described_class.estimate_from_attempt(nil)
      expect(result).to eq({ input_tokens: 0, output_tokens: 0 })
    end

    it "estimates tokens from attempt with string keys" do
      attempt = {
        "prompt" => "What is the capital of France?",
        "outputs" => [ "Paris is the capital of France." ]
      }

      result = described_class.estimate_from_attempt(attempt)

      expect(result[:input_tokens]).to be > 0
      expect(result[:output_tokens]).to be > 0
    end

    it "estimates tokens from attempt with symbol keys" do
      attempt = {
        prompt: "What is the capital of France?",
        outputs: [ "Paris is the capital of France." ]
      }

      result = described_class.estimate_from_attempt(attempt)

      expect(result[:input_tokens]).to be > 0
      expect(result[:output_tokens]).to be > 0
    end

    it "handles attempt with nil prompt" do
      attempt = {
        "prompt" => nil,
        "outputs" => [ "Some output" ]
      }

      result = described_class.estimate_from_attempt(attempt)

      expect(result[:input_tokens]).to eq(0)
      expect(result[:output_tokens]).to be > 0
    end

    it "handles attempt with nil outputs" do
      attempt = {
        "prompt" => "Some prompt",
        "outputs" => nil
      }

      result = described_class.estimate_from_attempt(attempt)

      expect(result[:input_tokens]).to be > 0
      expect(result[:output_tokens]).to eq(0)
    end

    it "handles attempt with multiple outputs" do
      attempt = {
        "prompt" => "Generate three words",
        "outputs" => [ "Apple", "Banana", "Cherry" ]
      }

      result = described_class.estimate_from_attempt(attempt)

      expect(result[:output_tokens]).to be >= 3
    end

    # garak 0.13.3+ structured prompt format tests
    context "with garak 0.13.3+ structured prompt format" do
      it "handles structured prompt with string content" do
        attempt = {
          "prompt" => {
            "turns" => [
              { "role" => "user", "content" => "What is the capital of France?" }
            ]
          },
          "outputs" => [ "Paris is the capital of France." ]
        }

        result = described_class.estimate_from_attempt(attempt)

        expect(result[:input_tokens]).to be > 0
        expect(result[:output_tokens]).to be > 0
      end

      it "handles structured prompt with hash content containing text" do
        attempt = {
          "prompt" => {
            "turns" => [
              {
                "role" => "user",
                "content" => {
                  "text" => "What is the capital of France?",
                  "lang" => "en"
                }
              }
            ]
          },
          "outputs" => [ "Paris is the capital of France." ]
        }

        result = described_class.estimate_from_attempt(attempt)

        expect(result[:input_tokens]).to be > 0
        expect(result[:output_tokens]).to be > 0
      end

      it "handles structured prompt with multiple turns" do
        attempt = {
          "prompt" => {
            "turns" => [
              { "role" => "system", "content" => "You are a helpful assistant." },
              { "role" => "user", "content" => "Hello" }
            ]
          },
          "outputs" => [ "Hi there!" ]
        }

        result = described_class.estimate_from_attempt(attempt)

        # Should count tokens from both turns
        expect(result[:input_tokens]).to be > 3
      end

      it "handles structured prompt with symbol keys" do
        attempt = {
          prompt: {
            turns: [
              { role: "user", content: { text: "What is AI?" } }
            ]
          },
          outputs: [ "AI stands for Artificial Intelligence." ]
        }

        result = described_class.estimate_from_attempt(attempt)

        expect(result[:input_tokens]).to be > 0
        expect(result[:output_tokens]).to be > 0
      end

      it "handles empty turns array" do
        attempt = {
          "prompt" => { "turns" => [] },
          "outputs" => [ "Some output" ]
        }

        result = described_class.estimate_from_attempt(attempt)

        expect(result[:input_tokens]).to eq(0)
        expect(result[:output_tokens]).to be > 0
      end

      it "handles missing turns key" do
        attempt = {
          "prompt" => { "other_key" => "value" },
          "outputs" => [ "Some output" ]
        }

        result = described_class.estimate_from_attempt(attempt)

        expect(result[:input_tokens]).to eq(0)
        expect(result[:output_tokens]).to be > 0
      end
    end
  end

  describe ".extract_prompt_text" do
    it "returns string prompt unchanged" do
      expect(described_class.extract_prompt_text("Hello world")).to eq("Hello world")
    end

    it "returns nil for nil prompt" do
      expect(described_class.extract_prompt_text(nil)).to be_nil
    end

    it "extracts text from garak 0.13.3+ structured format with string content" do
      prompt = {
        "turns" => [
          { "role" => "user", "content" => "What is AI?" }
        ]
      }
      expect(described_class.extract_prompt_text(prompt)).to eq("What is AI?")
    end

    it "extracts text from garak 0.13.3+ structured format with hash content" do
      prompt = {
        "turns" => [
          { "role" => "user", "content" => { "text" => "Explain quantum computing", "lang" => "en" } }
        ]
      }
      expect(described_class.extract_prompt_text(prompt)).to eq("Explain quantum computing")
    end

    it "concatenates text from multiple turns" do
      prompt = {
        "turns" => [
          { "role" => "system", "content" => "You are helpful." },
          { "role" => "user", "content" => "Hello" }
        ]
      }
      expect(described_class.extract_prompt_text(prompt)).to eq("You are helpful.\nHello")
    end

    it "skips the trailing assistant turn when conversation ends with assistant" do
      prompt = {
        "turns" => [
          { "role" => "user", "content" => "First question" },
          { "role" => "assistant", "content" => "First answer" },
          { "role" => "user", "content" => "Second question" },
          { "role" => "assistant", "content" => "Second answer" }
        ]
      }
      result = described_class.extract_prompt_text(prompt)
      expect(result).to include("First question")
      expect(result).to include("First answer")
      expect(result).to include("Second question")
      expect(result).not_to include("Second answer")
    end

    it "includes all assistant turns when conversation does not end with assistant" do
      prompt = {
        "turns" => [
          { "role" => "user", "content" => "First question" },
          { "role" => "assistant", "content" => "First answer" },
          { "role" => "user", "content" => "Second question" }
        ]
      }
      result = described_class.extract_prompt_text(prompt)
      expect(result).to include("First question")
      expect(result).to include("First answer")
      expect(result).to include("Second question")
    end

    it "includes all turns when there are no assistant turns" do
      prompt = {
        "turns" => [
          { "role" => "system", "content" => "You are helpful." },
          { "role" => "user", "content" => "Hello" }
        ]
      }
      expect(described_class.extract_prompt_text(prompt)).to eq("You are helpful.\nHello")
    end

    it "returns nil for hash without turns key" do
      expect(described_class.extract_prompt_text({ "other" => "value" })).to be_nil
    end

    it "returns empty string for empty turns array" do
      expect(described_class.extract_prompt_text({ "turns" => [] })).to eq("")
    end
  end

  describe ".extract_output_text" do
    it "returns string output unchanged" do
      expect(described_class.extract_output_text("Hello world")).to eq("Hello world")
    end

    it "returns nil for nil output" do
      expect(described_class.extract_output_text(nil)).to be_nil
    end

    it "extracts text from garak 0.13.3+ structured format" do
      output = {
        "text" => "This is the response",
        "lang" => nil,
        "data_path" => nil
      }
      expect(described_class.extract_output_text(output)).to eq("This is the response")
    end

    it "handles symbol keys" do
      output = { text: "Response with symbol key" }
      expect(described_class.extract_output_text(output)).to eq("Response with symbol key")
    end
  end

  describe ".estimate_from_attempts" do
    it "returns zeros for nil attempts" do
      result = described_class.estimate_from_attempts(nil)
      expect(result).to eq({ input_tokens: 0, output_tokens: 0 })
    end

    it "returns zeros for empty attempts array" do
      result = described_class.estimate_from_attempts([])
      expect(result).to eq({ input_tokens: 0, output_tokens: 0 })
    end

    it "aggregates tokens from multiple attempts" do
      attempts = [
        { "prompt" => "First question", "outputs" => [ "First answer" ] },
        { "prompt" => "Second question", "outputs" => [ "Second answer" ] }
      ]

      single_result = described_class.estimate_from_attempt(attempts.first)
      aggregate_result = described_class.estimate_from_attempts(attempts)

      expect(aggregate_result[:input_tokens]).to be > single_result[:input_tokens]
      expect(aggregate_result[:output_tokens]).to be > single_result[:output_tokens]
    end

    it "handles mixed valid and nil attempts" do
      attempts = [
        { "prompt" => "Valid question", "outputs" => [ "Valid answer" ] },
        nil
      ]

      result = described_class.estimate_from_attempts(attempts)

      expect(result[:input_tokens]).to be > 0
      expect(result[:output_tokens]).to be > 0
    end
  end
end
