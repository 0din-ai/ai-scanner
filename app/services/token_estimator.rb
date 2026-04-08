# frozen_string_literal: true

# Service for counting tokens in text using tiktoken (OpenAI's BPE tokenizer).
#
# ENCODING CHOICE: cl100k_base (GPT-4/ChatGPT baseline)
#
# This encoding is used as an intentional approximation for token estimation.
# Actual token counts vary by model:
# - OpenAI GPT-4/GPT-3.5: cl100k_base is exact
# - Anthropic Claude: Uses different tokenizer (~10-15% variance)
# - Other providers: Varies by model architecture
#
# The estimates are useful for:
# - Relative cost comparisons between scans
# - Rough usage tracking and projections
# - Identifying high-token prompts
#
# They should NOT be used for:
# - Exact billing calculations
# - Provider-specific quota enforcement
class TokenEstimator
  class << self
    # Count tokens in text
    # @param text [String, nil] The text to count tokens for
    # @return [Integer] Token count
    def estimate_tokens(text)
      return 0 if text.nil? || text.empty?

      encoder.encode(text).length
    end

    # Estimate input and output tokens from a single attempt
    # @param attempt [Hash] Attempt hash with 'prompt' and 'outputs' keys
    # @return [Hash] Hash with :input_tokens and :output_tokens
    def estimate_from_attempt(attempt)
      return { input_tokens: 0, output_tokens: 0 } if attempt.nil?

      prompt = attempt["prompt"] || attempt[:prompt]
      outputs = attempt["outputs"] || attempt[:outputs]

      {
        input_tokens: estimate_tokens(extract_prompt_text(prompt)),
        output_tokens: estimate_output_tokens(outputs)
      }
    end

    # Aggregate token estimates from multiple attempts
    # @param attempts [Array<Hash>] Array of attempt hashes
    # @return [Hash] Hash with :input_tokens and :output_tokens totals
    def estimate_from_attempts(attempts)
      return { input_tokens: 0, output_tokens: 0 } if attempts.nil? || attempts.empty?

      attempts.each_with_object({ input_tokens: 0, output_tokens: 0 }) do |attempt, totals|
        estimate = estimate_from_attempt(attempt)
        totals[:input_tokens] += estimate[:input_tokens]
        totals[:output_tokens] += estimate[:output_tokens]
      end
    end

    # Extract text from prompt which can be either a simple string or
    # a structured hash in garak 0.13.3+ format:
    # { "turns" => [{ "role" => "user", "content" => { "text" => "..." } }] }
    # @param prompt [String, Hash, nil] The prompt value
    # @return [String, nil] The extracted text or nil
    def extract_prompt_text(prompt)
      return prompt if prompt.is_a?(String)
      return nil if prompt.nil?

      # Handle garak 0.13.3+ structured format
      if prompt.is_a?(Hash)
        turns = prompt["turns"] || prompt[:turns]
        return nil unless turns.is_a?(Array)

        # Skip the trailing assistant turn to avoid double-counting output
        # tokens. Earlier assistant turns are legitimate input: multi-turn
        # probes resend prior assistant replies on each subsequent API call.
        # Only skip when the conversation actually ends with an assistant turn;
        # otherwise every assistant reply is genuine input context.
        last_idx = turns.size - 1
        skip_last = last_idx >= 0 && (turns[last_idx]["role"] || turns[last_idx][:role]) == "assistant"

        turns.each_with_index.filter_map do |turn, idx|
          next if skip_last && idx == last_idx

          content = turn["content"] || turn[:content]
          case content
          when String
            content
          when Hash
            content["text"] || content[:text]
          end
        end.join("\n")
      end
    end

    # Extract text from output which can be either a simple string or
    # a structured hash in garak 0.13.3+ format:
    # { "text" => "...", "lang" => null, ... }
    # @param output [String, Hash, nil] The output value
    # @return [String, nil] The extracted text or nil
    def extract_output_text(output)
      return output if output.is_a?(String)
      return nil if output.nil?

      # Handle garak 0.13.3+ structured format
      if output.is_a?(Hash)
        output["text"] || output[:text]
      end
    end

    private

    def encoder
      @encoder ||= Tiktoken.get_encoding("cl100k_base")
    end

    def estimate_output_tokens(outputs)
      return 0 if outputs.nil?

      Array(outputs).sum { |output| estimate_tokens(extract_output_text(output) || "") }
    end
  end
end
