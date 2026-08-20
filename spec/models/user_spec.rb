require 'rails_helper'

RSpec.describe User, type: :model do
  describe 'devise modules' do
    it 'uses appropriate devise modules' do
      expect(User.devise_modules).to include(:database_authenticatable)
      expect(User.devise_modules).to include(:recoverable)
      expect(User.devise_modules).to include(:rememberable)
      expect(User.devise_modules).to include(:validatable)
    end

    it 'does not expire inactive sessions' do
      expect(User.devise_modules).not_to include(:timeoutable)
    end
  end

  describe 'associations' do
    it { is_expected.to have_many(:memberships).dependent(:destroy) }
    it { is_expected.to have_many(:companies).through(:memberships) }
    it { is_expected.to belong_to(:current_company).class_name('Company').optional }

    describe '#company alias' do
      it 'returns current_company' do
        user = create(:user)
        expect(user.company).to eq(user.current_company)
      end
    end
  end

  describe 'validations' do
    it { is_expected.to validate_inclusion_of(:time_zone).in_array(ActiveSupport::TimeZone.all.map(&:name)).allow_blank }
  end

  describe 'super_admin functionality' do
    describe 'default values' do
      it 'defaults super_admin to false' do
        user = build(:user)
        expect(user.super_admin).to be false
      end
    end

    describe '#super_admin?' do
      it 'returns true for super admin users' do
        user = build(:user, :super_admin)
        expect(user.super_admin?).to be true
      end

      it 'returns false for regular admin users' do
        user = build(:user, :regular_admin)
        expect(user.super_admin?).to be false
      end
    end

    describe 'scopes' do
      let!(:super_admin) { create(:user, :super_admin) }
      let!(:regular_admin1) { create(:user, :regular_admin) }
      let!(:regular_admin2) { create(:user, :regular_admin) }

      describe '.super_admins' do
        it 'returns only super admin users' do
          expect(User.super_admins).to contain_exactly(super_admin)
        end
      end

      describe '.regular_admins' do
        it 'returns only regular admin users' do
          expect(User.regular_admins).to contain_exactly(regular_admin1, regular_admin2)
        end
      end
    end
  end

  describe '.ransackable_attributes' do
    it 'returns only safe searchable attributes' do
      expect(User.ransackable_attributes).to match_array(%w[
        current_company_id external_id created_at email id super_admin time_zone updated_at
      ])
    end

    it 'does not expose sensitive password/token fields' do
      sensitive_fields = %w[encrypted_password reset_password_token reset_password_sent_at remember_created_at]
      expect(User.ransackable_attributes & sensitive_fields).to be_empty
    end
  end

  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:user)).to be_valid
    end

    it 'has a valid super_admin trait' do
      expect(build(:user, :super_admin)).to be_valid
      expect(build(:user, :super_admin).super_admin?).to be true
    end

    it 'has a valid regular_admin trait' do
      expect(build(:user, :regular_admin)).to be_valid
      expect(build(:user, :regular_admin).super_admin?).to be false
    end
  end
end
