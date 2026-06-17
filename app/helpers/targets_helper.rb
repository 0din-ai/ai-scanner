module TargetsHelper
  GENERATOR_LABELS = {
    "AzureOpenAIGenerator" => "Azure OpenAI",
    "BedrockGenerator" => "Amazon Bedrock",
    "CohereGenerator" => "Cohere",
    "GgmlGenerator" => "GGML (Local)",
    "GroqChat" => "Groq Chat",
    "NeMoGuardrails" => "NVIDIA NeMo Guardrails",
    "InferenceAPI" => "HF Inference API",
    "InferenceEndpoint" => "Inference Endpoint",
    "LLaVA" => "LLaVA (Vision)",
    "LangChainLLMGenerator" => "LangChain",
    "LangChainServeLLMGenerator" => "LangChain Serve",
    "LiteLLMGenerator" => "LiteLLM",
    "MistralGenerator" => "Mistral AI",
    "NeMoGenerator" => "NVIDIA NeMo",
    "NVMultimodal" => "NVIDIA Multimodal",
    "NVOpenAIChat" => "NVIDIA OpenAI Chat",
    "NVOpenAICompletion" => "NVIDIA OpenAI Completion",
    "Vision" => "NVIDIA Vision",
    "NvcfChat" => "NVIDIA Cloud Functions Chat",
    "NvcfCompletion" => "NVIDIA Cloud Functions Completion",
    "OllamaGenerator" => "Ollama",
    "OllamaGeneratorChat" => "Ollama Chat",
    "OpenAICompatible" => "OpenAI Compatible",
    "OpenAIGenerator" => "OpenAI",
    "OpenAIReasoningGenerator" => "OpenAI Reasoning",
    "OpenRouterGenerator" => "OpenRouter",
    "RasaRestGenerator" => "Rasa REST",
    "ReplicateGenerator" => "Replicate",
    "RestGenerator" => "REST API (Generic)",
    "WatsonXGenerator" => "IBM watsonx"
  }.freeze

  EXCLUDED_GENERATORS = %w[
    Generator
    HFInternalServerError
    HFLoadingException
    HFRateLimitException
    Model
    Pipeline
  ].freeze

  PLATFORM_LABELS = {
    "azure" => "Azure",
    "bedrock" => "Amazon Bedrock",
    "cohere" => "Cohere",
    "ggml" => "GGML",
    "groq" => "Groq",
    "guardrails" => "NVIDIA Guardrails",
    "huggingface" => "Hugging Face",
    "langchain" => "LangChain",
    "langchain_serve" => "LangChain Serve",
    "litellm" => "LiteLLM",
    "mistral" => "Mistral",
    "nemo" => "NVIDIA NeMo",
    "nim" => "NVIDIA NIM",
    "nvcf" => "NVIDIA Cloud Functions",
    "ollama" => "Ollama",
    "openai" => "OpenAI",
    "openrouter" => "OpenRouter",
    "rasa" => "Rasa",
    "replicate" => "Replicate",
    "rest" => "REST API",
    "watsonx" => "IBM watsonx"
  }.freeze

  PROVIDER_TEMPLATES = {
    openrouter: {
      label: "OpenRouter",
      name: "OpenRouter (OpenAI Compatible)",
      model_type: "OpenRouterGenerator",
      model: "openai/gpt-4o",
      description: "Access many providers' models (including Claude) via OpenRouter — pick the model in the next step",
      json_config: "",
      icon: "icon-openrouter",
      icon_bg: "bg-green-500/20",
      icon_color: "text-green-400",
      badge: "Popular",
      badge_color: "bg-zinc-700/50 text-contentTertiary border-borderPrimary",
      env_var: "OPENROUTER_API_KEY"
    },
    openai: {
      label: "OpenAI",
      name: "OpenAI GPT-4o",
      model_type: "OpenAIGenerator",
      model: "gpt-4o",
      description: "OpenAI models (GPT-4o and others) — pick the model in the next step",
      json_config: "",
      icon: "icon-openai",
      icon_bg: "bg-green-500/20",
      icon_color: "text-green-400",
      badge: "Multimodal",
      badge_color: "bg-zinc-700/50 text-contentTertiary border-borderPrimary",
      env_var: "OPENAI_API_KEY"
    },
    gemini: {
      label: "Google Gemini",
      name: "Google Gemini 2.0 Flash",
      model_type: "RestGenerator",
      model: "gemini-2.0-flash-exp",
      description: "Google Gemini models via REST — pick the model in the next step",
      json_config: {
        rest: {
          RestGenerator: {
            name: "Google Gemini",
            uri: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=$GEMINI_API_KEY",
            method: "post",
            headers: { "Content-Type" => "application/json" },
            req_template_json_object: {
              contents: [ { parts: [ { text: "$INPUT" } ] } ],
              generationConfig: { temperature: 0.7, topK: 40, topP: 0.95, maxOutputTokens: 8192 }
            },
            response_json: true,
            response_json_field: "$.candidates[0].content.parts[0].text"
          }
        }
      }.to_json,
      icon: "icon-google",
      icon_bg: "bg-blue-500/20",
      icon_color: "text-blue-400",
      badge: "Multimodal",
      badge_color: "bg-zinc-700/50 text-contentTertiary border-borderPrimary",
      env_var: "GEMINI_API_KEY"
    },
    anthropic: {
      label: "Anthropic Claude",
      name: "Anthropic Claude",
      model_type: "RestGenerator",
      model: "claude-sonnet-4-5",
      description: "Claude via the Anthropic API — pick the model in the next step",
      json_config: {
        rest: {
          RestGenerator: {
            name: "Anthropic Claude",
            uri: "https://api.anthropic.com/v1/messages",
            method: "post",
            headers: {
              "x-api-key" => "$ANTHROPIC_API_KEY",
              "anthropic-version" => "2023-06-01",
              "content-type" => "application/json"
            },
            req_template_json_object: {
              model: "claude-sonnet-4-5",
              max_tokens: 1024,
              messages: [ { role: "user", content: "$INPUT" } ]
            },
            response_json: true,
            response_json_field: "$.content[0].text"
          }
        }
      }.to_json,
      icon: "icon-anthropic",
      icon_bg: "bg-orange-500/20",
      icon_color: "text-orange-400",
      badge: "Reasoning",
      badge_color: "bg-zinc-700/50 text-contentTertiary border-borderPrimary",
      env_var: "ANTHROPIC_API_KEY"
    },
    huggingface: {
      label: "Hugging Face",
      name: "Hugging Face Llama 3.3",
      model_type: "RestGenerator",
      model: "meta-llama/Llama-3.3-70B-Instruct",
      description: "Open models via Hugging Face's OpenAI-compatible API — pick the model in the next step",
      json_config: {
        rest: {
          RestGenerator: {
            name: "Hugging Face Llama 3.3",
            uri: "https://router.huggingface.co/v1/chat/completions",
            method: "post",
            headers: { "Authorization" => "Bearer $HF_INFERENCE_TOKEN", "Content-Type" => "application/json" },
            req_template_json_object: {
              model: "meta-llama/Llama-3.3-70B-Instruct",
              messages: [ { role: "user", content: "$INPUT" } ]
            },
            response_json: true,
            response_json_field: "$.choices[0].message.content"
          }
        }
      }.to_json,
      icon: "icon-huggingface",
      icon_bg: "bg-primary/20",
      icon_color: "text-primary",
      badge: "Open Source",
      badge_color: "bg-zinc-700/50 text-contentTertiary border-borderPrimary",
      env_var: "HF_INFERENCE_TOKEN"
    },
    ollama: {
      label: "Ollama",
      name: "Ollama Llama 3.3",
      model_type: "OllamaGenerator",
      model: "llama3.3:70b",
      description: "Run open models locally with Ollama — pick the model in the next step",
      json_config: { ollama: { OllamaGenerator: { model: "llama3.3:70b" } } }.to_json,
      icon: "icon-ollama",
      icon_bg: "bg-zinc-600/20",
      icon_color: "text-zinc-400",
      badge: "Local",
      badge_color: "bg-zinc-700/50 text-contentTertiary border-borderPrimary",
      env_var: "Ollama installed locally"
    },
    azure: {
      label: "Azure OpenAI",
      name: "Azure OpenAI",
      model_type: "AzureOpenAIGenerator",
      model: "gpt-4o",
      description: "Enterprise-grade OpenAI on Azure — set your endpoint and key as environment variables",
      json_config: {
        azure: { AzureOpenAIGenerator: { api_key: "$API_KEY", model_name: "gpt-4o", uri: "$AZURE_ENDPOINT" } }
      }.to_json,
      icon: "icon-azure",
      icon_bg: "bg-blue-500/20",
      icon_color: "text-blue-400",
      badge: "Enterprise",
      badge_color: "bg-zinc-700/50 text-contentTertiary border-borderPrimary",
      env_var: "Azure credentials"
    },
    deepinfra: {
      label: "Deep Infra",
      name: "Deep Infra (Llama 3.3)",
      model_type: "LiteLLMGenerator",
      model: "deepinfra/meta-llama/Llama-3.3-70B-Instruct",
      description: "Open models via Deep Infra — pick the model in the next step",
      json_config: {
        litellm: { LiteLLMGenerator: { api_base: "https://api.deepinfra.com/v1/openai", model: "meta-llama/Llama-3.3-70B-Instruct" } }
      }.to_json,
      icon: "icon-deepinfra",
      icon_bg: "bg-pink-500/20",
      icon_color: "text-pink-400",
      badge: "Fast",
      badge_color: "bg-zinc-700/50 text-contentTertiary border-borderPrimary",
      env_var: "DEEPINFRA_API_KEY"
    }
  }.freeze

  def target_status_indicator(target, additional_classes = "")
    return "" unless target&.status

    case target.status
    when "good"
      content_tag(:div, "", class: "w-3 h-3 shrink-0 bg-lime-400 rounded-full shadow-sm cursor-help #{additional_classes}", title: "Good - Target is validated and ready")
    when "validating"
      content_tag(:div, "", class: "w-3 h-3 shrink-0 bg-zinc-500 rounded-full shadow-sm animate-pulse cursor-help #{additional_classes}", title: "Validating - Target is currently being validated")
    when "bad"
      content_tag(:div, "", class: "w-3 h-3 shrink-0 bg-red-400 rounded-full shadow-sm cursor-help #{additional_classes}", title: "Bad - Target has validation issues")
    else
      ""
    end
  end

  def grouped_model_type_options
    Target::MODEL_TYPES.except("base", "web_chatbot").filter_map do |platform, generators|
      valid = generators.reject { |g| EXCLUDED_GENERATORS.include?(g) }
      next if valid.empty?

      label = PLATFORM_LABELS[platform] || platform.titleize
      options = valid.map { |g| [ GENERATOR_LABELS[g] || g, g ] }
      [ label, options ]
    end
  end

  def provider_templates
    PROVIDER_TEMPLATES
  end

  def provider_templates_for_js
    PROVIDER_TEMPLATES.transform_values do |t|
      t.slice(:label, :name, :model_type, :model, :description, :json_config)
    end
  end

  def infer_provider_from_target(target)
    return "" unless target.model_type.present?
    return "webchat" if target.webchat?

    matches = PROVIDER_TEMPLATES.select { |_, t| t[:model_type] == target.model_type }
    return matches.keys.first.to_s if matches.size == 1

    matches.each do |key, template|
      return key.to_s if template[:model] == target.model
    end

    # Still ambiguous (e.g. an edited RestGenerator model): disambiguate by the
    # exact API host of the saved json_config URI. Parse the host rather than a
    # substring match so a look-alike host (api.anthropic.com.evil.test) can't match.
    host = rest_config_host(target.json_config)
    return "anthropic" if host == "api.anthropic.com"
    return "gemini" if host == "generativelanguage.googleapis.com"
    return "huggingface" if host == "huggingface.co" || host.end_with?(".huggingface.co")

    "custom"
  end

  def rest_config_host(json_config)
    parsed = JSON.parse(json_config.to_s)
    rest = parsed.is_a?(Hash) ? parsed["rest"] : nil
    generator = rest.is_a?(Hash) ? rest["RestGenerator"] : nil
    uri = generator.is_a?(Hash) ? generator["uri"] : nil
    URI.parse(uri.to_s).host.to_s
  rescue JSON::ParserError, URI::Error
    ""
  end
end
