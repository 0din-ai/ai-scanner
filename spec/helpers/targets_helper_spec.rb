require 'rails_helper'

RSpec.describe TargetsHelper, type: :helper do
  describe '#target_status_indicator' do
    context 'when target has good status' do
      let(:target) { build(:target, :good) }

      it 'returns emerald green indicator with correct classes' do
        result = helper.target_status_indicator(target)

        expect(result).to include('bg-lime-400')
        expect(result).to include('w-3 h-3')
        expect(result).to include('rounded-full')
        expect(result).to include('shadow-sm')
        expect(result).to include('cursor-help')
      end

      it 'includes correct tooltip for good status' do
        result = helper.target_status_indicator(target)

        expect(result).to include('title="Good - Target is validated and ready"')
      end

      it 'applies additional classes when provided' do
        result = helper.target_status_indicator(target, "mx-auto test-class")

        expect(result).to include('mx-auto test-class')
      end

      it 'returns a div element' do
        result = helper.target_status_indicator(target)

        expect(result).to start_with('<div')
        expect(result).to end_with('</div>')
      end
    end

    context 'when target has validating status' do
      let(:target) { build(:target, :validating) }

      it 'returns grey indicator with animation' do
        result = helper.target_status_indicator(target)

        expect(result).to include('bg-zinc-500')
        expect(result).to include('animate-pulse')
        expect(result).to include('w-3 h-3')
        expect(result).to include('rounded-full')
        expect(result).to include('shadow-sm')
        expect(result).to include('cursor-help')
      end

      it 'includes correct tooltip for validating status' do
        result = helper.target_status_indicator(target)

        expect(result).to include('title="Validating - Target is currently being validated"')
      end

      it 'applies additional classes when provided' do
        result = helper.target_status_indicator(target, "mr-2")

        expect(result).to include('mr-2')
      end
    end

    context 'when target has bad status' do
      let(:target) { build(:target, :bad) }

      it 'returns red indicator' do
        result = helper.target_status_indicator(target)

        expect(result).to include('bg-red-400')
        expect(result).to include('w-3 h-3')
        expect(result).to include('rounded-full')
        expect(result).to include('shadow-sm')
        expect(result).to include('cursor-help')
      end

      it 'includes correct tooltip for bad status' do
        result = helper.target_status_indicator(target)

        expect(result).to include('title="Bad - Target has validation issues"')
      end

      it 'applies additional classes when provided' do
        result = helper.target_status_indicator(target, "ml-4 custom-class")

        expect(result).to include('ml-4 custom-class')
      end
    end

    context 'when target has unknown status' do
      let(:target) { build(:target) }

      before do
        # Bypass enum validation by directly setting the status attribute
        target.instance_variable_set(:@status, 'unknown')
        allow(target).to receive(:status).and_return('unknown')
      end

      it 'returns empty string for unknown status' do
        result = helper.target_status_indicator(target)

        expect(result).to eq('')
      end
    end

    context 'when target is nil' do
      it 'returns empty string' do
        result = helper.target_status_indicator(nil)

        expect(result).to eq('')
      end
    end

    context 'when target has no status' do
      let(:target) { build(:target) }

      before do
        target.status = nil
      end

      it 'returns empty string' do
        result = helper.target_status_indicator(target)

        expect(result).to eq('')
      end
    end

    context 'when additional_classes parameter is empty' do
      let(:target) { build(:target, :good) }

      it 'works correctly without additional classes' do
        result = helper.target_status_indicator(target, "")

        expect(result).to include('bg-lime-400')
        expect(result).not_to include('class="w-3 h-3 bg-lime-400 rounded-full shadow-sm cursor-help  "')
      end
    end

    context 'when additional_classes parameter is not provided' do
      let(:target) { build(:target, :good) }

      it 'works correctly with default additional_classes' do
        result = helper.target_status_indicator(target)

        expect(result).to include('bg-lime-400')
        expect(result).to include('w-3 h-3')
      end
    end

    context 'HTML safety' do
      let(:target) { build(:target, :good) }

      it 'returns HTML safe string' do
        result = helper.target_status_indicator(target)

        expect(result).to be_html_safe
      end

      it 'handles malicious additional classes safely' do
        malicious_class = '"><script>alert("xss")</script><div class="'
        result = helper.target_status_indicator(target, malicious_class)

        # The malicious script should be escaped/safe
        expect(result).to be_html_safe
        # Check that the malicious script is HTML escaped
        expect(result).to include('&quot;&gt;&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;&lt;div class=&quot;')
      end
    end

    context 'integration with different target statuses' do
      it 'handles all valid target statuses correctly' do
        %w[good validating bad].each do |status|
          target = build(:target)
          target.status = status

          result = helper.target_status_indicator(target)

          expect(result).not_to be_empty
          expect(result).to include('w-3 h-3')
          expect(result).to include('rounded-full')
        end
      end
    end

    context 'CSS class structure' do
      let(:target) { build(:target, :good) }

      it 'maintains consistent CSS class structure' do
        result = helper.target_status_indicator(target, "additional-class")

        # Verify all required CSS classes are present
        expect(result).to include('w-3')
        expect(result).to include('h-3')
        expect(result).to include('bg-lime-400')
        expect(result).to include('rounded-full')
        expect(result).to include('shadow-sm')
        expect(result).to include('cursor-help')
        expect(result).to include('additional-class')
      end
    end
  end

  describe '#infer_provider_from_target' do
    context 'when model_type is blank' do
      let(:target) { build(:target) }

      before { allow(target).to receive(:model_type).and_return(nil) }

      it 'returns empty string' do
        expect(helper.infer_provider_from_target(target)).to eq('')
      end
    end

    context 'when target is webchat' do
      let(:target) { build(:target, :webchat, model_type: 'web_chatbot') }

      it 'returns "webchat"' do
        expect(helper.infer_provider_from_target(target)).to eq('webchat')
      end
    end

    context 'when model_type uniquely matches a provider template' do
      it 'returns "openai" for OpenAIGenerator' do
        target = build(:target, model_type: 'OpenAIGenerator', model: 'gpt-4o')
        expect(helper.infer_provider_from_target(target)).to eq('openai')
      end

      it 'returns "openrouter" for OpenRouterGenerator' do
        target = build(:target, model_type: 'OpenRouterGenerator', model: 'openai/gpt-4o')
        expect(helper.infer_provider_from_target(target)).to eq('openrouter')
      end

      it 'returns "ollama" for OllamaGenerator' do
        target = build(:target, model_type: 'OllamaGenerator', model: 'llama3.3:70b')
        expect(helper.infer_provider_from_target(target)).to eq('ollama')
      end

      it 'returns "azure" for AzureOpenAIGenerator' do
        target = build(:target, model_type: 'AzureOpenAIGenerator', model: 'gpt-4o')
        expect(helper.infer_provider_from_target(target)).to eq('azure')
      end
    end

    context 'when model_type is shared by multiple templates (RestGenerator)' do
      it 'returns "gemini" when model matches gemini template' do
        target = build(:target, model_type: 'RestGenerator', model: 'gemini-2.0-flash-exp')
        expect(helper.infer_provider_from_target(target)).to eq('gemini')
      end

      it 'returns "huggingface" when model matches huggingface template' do
        target = build(:target, model_type: 'RestGenerator', model: 'meta-llama/Llama-3.3-70B-Instruct')
        expect(helper.infer_provider_from_target(target)).to eq('huggingface')
      end

      it 'returns "custom" when model matches neither template' do
        target = build(:target, model_type: 'RestGenerator', model: 'some-other-model')
        expect(helper.infer_provider_from_target(target)).to eq('custom')
      end
    end

    context 'when model_type is unknown' do
      it 'returns "custom"' do
        target = build(:target, model_type: 'SomeUnknownGenerator', model: 'test')
        expect(helper.infer_provider_from_target(target)).to eq('custom')
      end
    end
  end

  describe '#grouped_model_type_options' do
    subject(:options) { helper.grouped_model_type_options }

    it 'returns an array of [label, options] pairs' do
      expect(options).to all(be_an(Array))
      options.each do |label, group_options|
        expect(label).to be_a(String)
        expect(group_options).to all(be_an(Array).and(have_attributes(size: 2)))
      end
    end

    it 'excludes base and web_chatbot platforms' do
      platform_labels = options.map(&:first)
      expect(platform_labels).not_to include('base')
      expect(platform_labels).not_to include('web_chatbot')
    end

    it 'excludes generators in EXCLUDED_GENERATORS' do
      all_generators = options.flat_map { |_, group| group.map(&:last) }
      TargetsHelper::EXCLUDED_GENERATORS.each do |excluded|
        expect(all_generators).not_to include(excluded)
      end
    end

    it 'uses PLATFORM_LABELS for known platforms' do
      platform_labels = options.map(&:first)
      # OpenAI platform should use the label from PLATFORM_LABELS
      expect(platform_labels).to include('OpenAI') if Target::MODEL_TYPES.key?('openai')
    end

    it 'uses GENERATOR_LABELS for known generators' do
      all_labels = options.flat_map { |_, group| group.map(&:first) }
      # OpenAIGenerator should be labeled "OpenAI" from GENERATOR_LABELS
      expect(all_labels).to include('OpenAI') if Target::MODEL_TYPES.values.flatten.include?('OpenAIGenerator')
    end
  end

  describe '#provider_templates_for_js' do
    subject(:js_templates) { helper.provider_templates_for_js }

    let(:allowed_keys) { %i[label name model_type model description json_config] }

    it 'returns a hash with same keys as PROVIDER_TEMPLATES' do
      expect(js_templates.keys).to match_array(TargetsHelper::PROVIDER_TEMPLATES.keys)
    end

    it 'only includes label, name, model_type, model, description, and json_config' do
      js_templates.each_value do |template|
        expect(template.keys).to match_array(allowed_keys)
      end
    end

    it 'does not expose icon, badge, or env_var fields' do
      internal_keys = %i[icon icon_bg icon_color badge badge_color env_var]
      js_templates.each_value do |template|
        internal_keys.each do |key|
          expect(template).not_to have_key(key)
        end
      end
    end
  end

  describe 'PROVIDER_TEMPLATES labels and Anthropic tile' do
    it 'gives every template a provider-name :label (no model suffix)' do
      TargetsHelper::PROVIDER_TEMPLATES.each_value do |t|
        expect(t[:label]).to be_present
      end
      expect(TargetsHelper::PROVIDER_TEMPLATES[:openai][:label]).to eq('OpenAI')
      expect(TargetsHelper::PROVIDER_TEMPLATES[:gemini][:label]).to eq('Google Gemini')
      expect(TargetsHelper::PROVIDER_TEMPLATES[:huggingface][:label]).to eq('Hugging Face')
      expect(TargetsHelper::PROVIDER_TEMPLATES[:ollama][:label]).to eq('Ollama')
      expect(TargetsHelper::PROVIDER_TEMPLATES[:deepinfra][:label]).to eq('Deep Infra')
    end

    it 'includes a first-class Anthropic Claude tile via the Anthropic API' do
      t = TargetsHelper::PROVIDER_TEMPLATES[:anthropic]
      expect(t).to be_present
      expect(t[:label]).to eq('Anthropic Claude')
      expect(t[:model_type]).to eq('RestGenerator')
      expect(t[:env_var]).to eq('ANTHROPIC_API_KEY')
      config = JSON.parse(t[:json_config])
      expect(config.dig('rest', 'RestGenerator', 'uri')).to include('api.anthropic.com')
      expect(config.dig('rest', 'RestGenerator', 'response_json_field')).to eq('$.content[0].text')
    end

    it 'exposes :label to the JS templates' do
      js = helper.provider_templates_for_js
      expect(js[:anthropic]).to include(:label, :model_type, :model, :json_config)
      expect(js[:gemini][:label]).to eq('Google Gemini')
    end
  end

  describe '#infer_provider_from_target with three RestGenerator templates' do
    it 'infers anthropic for a Claude RestGenerator target' do
      target = build(:target, model_type: 'RestGenerator', model: 'claude-sonnet-4-5',
                              json_config: TargetsHelper::PROVIDER_TEMPLATES[:anthropic][:json_config])
      expect(helper.infer_provider_from_target(target)).to eq('anthropic')
    end

    it 'still infers gemini and huggingface correctly' do
      gemini = build(:target, model_type: 'RestGenerator', model: 'gemini-2.0-flash-exp',
                              json_config: TargetsHelper::PROVIDER_TEMPLATES[:gemini][:json_config])
      hf = build(:target, model_type: 'RestGenerator', model: 'meta-llama/Llama-3.3-70B-Instruct',
                          json_config: TargetsHelper::PROVIDER_TEMPLATES[:huggingface][:json_config])
      expect(helper.infer_provider_from_target(gemini)).to eq('gemini')
      expect(helper.infer_provider_from_target(hf)).to eq('huggingface')
    end

    it 'falls back to the json_config host when the model was edited' do
      target = build(:target, model_type: 'RestGenerator', model: 'claude-opus-4-1',
                              json_config: TargetsHelper::PROVIDER_TEMPLATES[:anthropic][:json_config])
      expect(helper.infer_provider_from_target(target)).to eq('anthropic')
    end

    it 'does not infer a provider from a look-alike host' do
      target = build(:target, model_type: 'RestGenerator', model: 'claude-x',
                              json_config: { rest: { RestGenerator: { uri: 'https://api.anthropic.com.evil.test/v1/messages' } } }.to_json)
      expect(helper.infer_provider_from_target(target)).to eq('custom')
    end

    it 'falls back to custom for non-object or malformed json_config without raising' do
      [ '[1, 2, 3]', '"just a string"', '42', '{"rest": "not-an-object"}', '{}' ].each do |cfg|
        target = build(:target, model_type: 'RestGenerator', model: 'claude-x', json_config: cfg)
        expect(helper.infer_provider_from_target(target)).to eq('custom')
      end
    end
  end

  describe 'PROVIDER_TEMPLATES' do
    it 'has valid JSON in json_config for all templates with config' do
      TargetsHelper::PROVIDER_TEMPLATES.each do |key, template|
        next if template[:json_config].blank?

        expect { JSON.parse(template[:json_config]) }.not_to raise_error,
          "Invalid JSON in #{key} template json_config"
      end
    end

    it 'has required keys for every template' do
      required_keys = %i[name model_type model description icon badge badge_color]
      TargetsHelper::PROVIDER_TEMPLATES.each do |key, template|
        required_keys.each do |rk|
          expect(template).to have_key(rk), "#{key} template missing :#{rk}"
        end
      end
    end
  end
end
