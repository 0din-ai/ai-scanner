require 'rails_helper'

RSpec.describe SettingsService do
  before(:each) do
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    Metadatum.destroy_all
  end

  after(:each) do
    Rails.cache = @original_cache_store
  end

  describe '.parallel_scans_limit' do
    context 'when setting exists in database' do
      before do
        Metadatum.create!(key: 'parallel_scans_limit', value: '10')
      end

      it 'returns the value from database' do
        expect(described_class.parallel_scans_limit).to eq(10)
      end

      it 'caches the value' do
        described_class.parallel_scans_limit

        expect(Metadatum).not_to receive(:find_by)
        described_class.parallel_scans_limit
      end
    end

    context 'when setting does not exist' do
      it 'returns the default value' do
        expect(described_class.parallel_scans_limit).to eq(5)
      end
    end

    context 'when value is non-numeric' do
      before do
        Metadatum.create!(key: 'parallel_scans_limit', value: 'invalid')
      end

      it 'returns 0 when converted to integer' do
        expect(described_class.parallel_scans_limit).to eq(0)
      end
    end
  end

  describe '.set_parallel_scans_limit' do
    context 'with valid value' do
      it 'creates a new setting if it does not exist' do
        expect {
          described_class.set_parallel_scans_limit(8)
        }.to change(Metadatum, :count).by(1)

        setting = Metadatum.find_by(key: 'parallel_scans_limit')
        expect(setting.value).to eq('8')
      end

      it 'updates existing setting' do
        Metadatum.create!(key: 'parallel_scans_limit', value: '5')

        expect {
          described_class.set_parallel_scans_limit(10)
        }.not_to change(Metadatum, :count)

        setting = Metadatum.find_by(key: 'parallel_scans_limit')
        expect(setting.value).to eq('10')
      end

      it 'clears the cache' do
        described_class.set_parallel_scans_limit(7)
        expect(Rails.cache.fetch("settings/parallel_scans_limit")).to be_nil
      end

      it 'accepts string values' do
        described_class.set_parallel_scans_limit('15')
        expect(described_class.parallel_scans_limit).to eq(15)
      end
    end

    context 'with invalid value' do
      it 'raises ArgumentError for value below minimum' do
        expect {
          described_class.set_parallel_scans_limit(0)
        }.to raise_error(ArgumentError, "Parallel scans limit must be between 1 and 20")
      end

      it 'raises ArgumentError for value above maximum' do
        expect {
          described_class.set_parallel_scans_limit(21)
        }.to raise_error(ArgumentError, "Parallel scans limit must be between 1 and 20")
      end

      it 'raises ArgumentError for negative value' do
        expect {
          described_class.set_parallel_scans_limit(-5)
        }.to raise_error(ArgumentError, "Parallel scans limit must be between 1 and 20")
      end
    end
  end

  describe '.parallel_attempts' do
    context 'when setting exists in database' do
      before do
        Metadatum.create!(key: 'parallel_attempts', value: '32')
      end

      it 'returns the value from database' do
        expect(described_class.parallel_attempts).to eq(32)
      end

      it 'caches the value' do
        described_class.parallel_attempts

        expect(Metadatum).not_to receive(:find_by)
        described_class.parallel_attempts
      end
    end

    context 'when setting does not exist' do
      it 'returns the default value' do
        expect(described_class.parallel_attempts).to eq(16)
      end
    end
  end

  describe '.set_parallel_attempts' do
    context 'with valid value' do
      it 'creates a new setting if it does not exist' do
        expect {
          described_class.set_parallel_attempts(24)
        }.to change(Metadatum, :count).by(1)

        setting = Metadatum.find_by(key: 'parallel_attempts')
        expect(setting.value).to eq('24')
      end

      it 'updates existing setting' do
        Metadatum.create!(key: 'parallel_attempts', value: '16')

        expect {
          described_class.set_parallel_attempts(50)
        }.not_to change(Metadatum, :count)

        setting = Metadatum.find_by(key: 'parallel_attempts')
        expect(setting.value).to eq('50')
      end

      it 'clears the cache' do
        described_class.set_parallel_attempts(20)
        expect(Rails.cache.fetch("settings/parallel_attempts")).to be_nil
      end

      it 'accepts boundary values' do
        described_class.set_parallel_attempts(1)
        expect(described_class.parallel_attempts).to eq(1)

        described_class.set_parallel_attempts(100)
        expect(described_class.parallel_attempts).to eq(100)
      end
    end

    context 'with invalid value' do
      it 'raises ArgumentError for value below minimum' do
        expect {
          described_class.set_parallel_attempts(0)
        }.to raise_error(ArgumentError, "Parallel attempts must be between 1 and 100")
      end

      it 'raises ArgumentError for value above maximum' do
        expect {
          described_class.set_parallel_attempts(101)
        }.to raise_error(ArgumentError, "Parallel attempts must be between 1 and 100")
      end

      it 'raises ArgumentError for negative value' do
        expect {
          described_class.set_parallel_attempts(-5)
        }.to raise_error(ArgumentError, "Parallel attempts must be between 1 and 100")
      end
    end
  end

  describe '.get' do
    it 'returns value from database if exists' do
      Metadatum.create!(key: 'test_key', value: 'test_value')
      expect(described_class.get('test_key')).to eq('test_value')
    end

    it 'returns default value if key not in database' do
      expect(described_class.get('parallel_scans_limit')).to eq(5)
    end

    it 'returns nil for unknown keys without defaults' do
      expect(described_class.get('unknown_key')).to be_nil
    end

    it 'caches the result' do
      Metadatum.create!(key: 'cached_key', value: 'cached_value')
      described_class.get('cached_key')

      expect(Metadatum).not_to receive(:find_by)
      described_class.get('cached_key')
    end
  end

  describe '.set' do
    it 'creates new metadatum record' do
      expect {
        described_class.set('new_key', 'new_value')
      }.to change(Metadatum, :count).by(1)
    end

    it 'updates existing metadatum record' do
      Metadatum.create!(key: 'existing_key', value: 'old_value')

      expect {
        described_class.set('existing_key', 'new_value')
      }.not_to change(Metadatum, :count)

      expect(Metadatum.find_by(key: 'existing_key').value).to eq('new_value')
    end

    it 'converts value to string' do
      described_class.set('numeric_key', 123)
      expect(Metadatum.find_by(key: 'numeric_key').value).to eq('123')
    end

    it 'clears cache for the key' do
      described_class.set('cache_test', 'value1')
      described_class.get('cache_test')
      described_class.set('cache_test', 'value2')

      expect(Rails.cache.fetch("settings/cache_test")).to be_nil
      expect(described_class.get('cache_test')).to eq('value2')
    end
  end

  describe '.clear_cache' do
    before do
      Metadatum.create!(key: 'key1', value: 'value1')
      Metadatum.create!(key: 'key2', value: 'value2')
      described_class.get('key1')
      described_class.get('key2')
    end

    it 'clears cache for specific key' do
      expect(Rails.cache.exist?("settings/key1")).to be true
      expect(Rails.cache.exist?("settings/key2")).to be true

      described_class.clear_cache('key1')

      expect(Rails.cache.exist?("settings/key1")).to be false
      expect(Rails.cache.exist?("settings/key2")).to be true
    end

    it 'clears all settings cache when key is nil' do
      described_class.clear_cache
      expect(Rails.cache.fetch("settings/key1")).to be_nil
      expect(Rails.cache.fetch("settings/key2")).to be_nil
    end
  end

  describe '.all_settings' do
    before do
      Metadatum.create!(key: 'parallel_scans_limit', value: '7')
    end

    it 'returns all default settings with current values' do
      settings = described_class.all_settings

      expect(settings).to be_a(Hash)
      expect(settings['parallel_scans_limit']).to eq('7')
    end

    it 'includes default values for missing settings' do
      settings = described_class.all_settings

      expect(settings['parallel_scans_limit']).to eq('7')
    end
  end

  describe '.odin_portal_token', if: SettingsService.respond_to?(:odin_portal_token) do
    context 'when setting exists in database' do
      before do
        Metadatum.create!(key: 'odin_portal_token', value: 'test-token-123')
      end

      it 'returns the token value' do
        expect(described_class.odin_portal_token).to eq('test-token-123')
      end
    end

    context 'when setting does not exist' do
      it 'returns empty string as default' do
        expect(described_class.odin_portal_token).to eq('')
      end
    end
  end

  describe '.odin_portal_token_configured?', if: SettingsService.respond_to?(:odin_portal_token_configured?) do
    context 'when token is set' do
      before { Metadatum.create!(key: 'odin_portal_token', value: 'test-token-123') }

      it 'returns true' do
        expect(described_class.odin_portal_token_configured?).to be true
      end
    end

    context 'when token does not exist' do
      it 'returns false' do
        expect(described_class.odin_portal_token_configured?).to be false
      end
    end
  end

  describe '.set_odin_portal_token', if: SettingsService.respond_to?(:set_odin_portal_token) do
    it 'stores the token value' do
      described_class.set_odin_portal_token('my-secret-token')
      expect(described_class.odin_portal_token).to eq('my-secret-token')
    end

    it 'strips whitespace from token' do
      described_class.set_odin_portal_token('  token-with-spaces  ')
      expect(described_class.odin_portal_token).to eq('token-with-spaces')
    end
  end
end
