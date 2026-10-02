# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MetadatumPolicy do
  let(:company) { create(:company) }
  let(:user) { create(:user, current_company: company) }
  let(:metadatum) { create(:metadatum) }

  describe 'inheritance' do
    it 'inherits from TenantScopedPolicy' do
      expect(described_class.superclass).to eq(TenantScopedPolicy)
    end
  end

  describe 'permissions' do
    context 'as a regular user' do
      subject { described_class.new(user, metadatum) }

      it { is_expected.to be_index }
      it { is_expected.to be_show }
      it { is_expected.not_to be_create }
      it { is_expected.not_to be_update }
      it { is_expected.not_to be_destroy }
    end

    context 'as a super admin' do
      let(:super_admin) { create(:user, current_company: company, super_admin: true) }
      subject { described_class.new(super_admin, metadatum) }

      it { is_expected.to be_index }
      it { is_expected.to be_show }
      it { is_expected.to be_create }
      it { is_expected.to be_update }
      it { is_expected.to be_destroy }
    end
  end

  describe 'judge_* keys' do
    let(:super_admin) { create(:user, current_company: company, super_admin: true) }
    let(:judge_row) { create(:metadatum, key: 'judge_enabled', value: 'true') }

    it 'refuses create, update and destroy even to a super admin' do
      policy = described_class.new(super_admin, judge_row)
      expect(policy.create?).to be(false)
      expect(policy.update?).to be(false)
      expect(policy.destroy?).to be(false)
    end

    it 'refuses a rename of an ordinary row into the judge namespace' do
      metadatum.key = 'judge_model_name'
      expect(described_class.new(super_admin, metadatum).update?).to be(false)
    end

    it 'refuses a rename of a judge row out of the judge namespace' do
      judge_row.key = 'harmless'
      expect(described_class.new(super_admin, judge_row).update?).to be(false)
    end

    it 'shows judge rows only to a super admin' do
      expect(described_class.new(super_admin, judge_row).show?).to be(true)
      expect(described_class.new(user, judge_row).show?).to be(false)
    end

    it 'scopes judge rows out for a member but not for a super admin' do
      judge_row
      lookalike = create(:metadatum, key: 'judgeXnot_protected')

      expect(described_class::Scope.new(user, Metadatum).resolve).not_to include(judge_row)
      expect(described_class::Scope.new(user, Metadatum).resolve).to include(lookalike)
      expect(described_class::Scope.new(super_admin, Metadatum).resolve).to include(judge_row)
    end
  end

  describe 'Scope' do
    # Metadatum doesn't have acts_as_tenant - it's a global resource
    let!(:meta1) { create(:metadatum) }
    let!(:meta2) { create(:metadatum) }

    it 'returns all metadata (global resource)' do
      scope = described_class::Scope.new(user, Metadatum).resolve
      expect(scope).to include(meta1, meta2)
    end
  end
end
