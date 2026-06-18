require 'rails_helper'

RSpec.describe EnvironmentVariable, type: :model do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:env_name) }
    it { is_expected.to validate_presence_of(:env_value) }

    describe 'uniqueness' do
      subject { create(:environment_variable) }
      it { is_expected.to validate_uniqueness_of(:env_name).scoped_to([ :company_id, :target_id ]) }
    end

    describe 'EVALUATION_THRESHOLD numericality' do
      let(:company) { create(:company) }

      it 'accepts a numeric value within [0, 1]' do
        ActsAsTenant.with_tenant(company) do
          env_var = build(:global_environment_variable, company: company,
                          env_name: 'EVALUATION_THRESHOLD', env_value: '0.2')
          expect(env_var).to be_valid
        end
      end

      it 'rejects a non-numeric value' do
        ActsAsTenant.with_tenant(company) do
          env_var = build(:global_environment_variable, company: company,
                          env_name: 'EVALUATION_THRESHOLD', env_value: 'abc')
          expect(env_var).not_to be_valid
        end
      end

      it 'rejects a value outside [0, 1]' do
        ActsAsTenant.with_tenant(company) do
          env_var = build(:global_environment_variable, company: company,
                          env_name: 'EVALUATION_THRESHOLD', env_value: '1.5')
          expect(env_var).not_to be_valid
        end
      end

      it 'does not over-reach: a non-threshold env var keeps accepting arbitrary values' do
        ActsAsTenant.with_tenant(company) do
          env_var = build(:global_environment_variable, company: company,
                          env_name: 'OPENAI_API_KEY', env_value: 'sk-xyz')
          expect(env_var).to be_valid
        end
      end
    end
  end

  describe 'associations' do
    it { is_expected.to belong_to(:target).optional }
  end

  describe 'scopes' do
    describe '.global' do
      it 'returns environment variables without a target' do
        global_var = create(:global_environment_variable)
        target_var = create(:environment_variable, :with_target)

        expect(EnvironmentVariable.global).to include(global_var)
        expect(EnvironmentVariable.global).not_to include(target_var)
      end
    end
  end

  describe '.ransackable_attributes' do
    it 'returns the correct attributes' do
      expect(EnvironmentVariable.ransackable_attributes).to match_array([
        "created_at", "env_name", "id", "target_id", "updated_at"
      ])
    end
  end

  describe '.ransackable_associations' do
    it 'returns the correct associations' do
      expect(EnvironmentVariable.ransackable_associations).to match_array([ "target" ])
    end
  end

  describe '.evaluation_threshold_for' do
    let(:company) { create(:company) }
    let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }

    it 'returns the target override value when set' do
      ActsAsTenant.with_tenant(company) do
        create(:global_environment_variable, company: company, env_name: 'EVALUATION_THRESHOLD', env_value: '0.2')
        create(:environment_variable, :with_target, company: company, target: target, env_name: 'EVALUATION_THRESHOLD', env_value: '0.7')

        expect(described_class.evaluation_threshold_for(target)).to eq(0.7)
      end
    end

    it 'falls back to the global value when the target has no override' do
      ActsAsTenant.with_tenant(company) do
        create(:global_environment_variable, company: company, env_name: 'EVALUATION_THRESHOLD', env_value: '0.2')

        expect(described_class.evaluation_threshold_for(target)).to eq(0.2)
      end
    end

    it "falls back to garak's 0.5 default when no env var is configured" do
      ActsAsTenant.with_tenant(company) do
        expect(described_class.evaluation_threshold_for(target)).to eq(0.5)
      end
    end
  end

  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:environment_variable)).to be_valid
    end

    it 'has a valid global factory' do
      expect(build(:global_environment_variable)).to be_valid
    end

    it 'can be associated with a target' do
      env_var = create(:environment_variable, :with_target)
      expect(env_var.target).to be_present
    end
  end
end
