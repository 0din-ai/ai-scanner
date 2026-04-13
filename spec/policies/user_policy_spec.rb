# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPolicy do
  let(:company_a) { create(:company) }
  let(:company_b) { create(:company) }
  let(:super_admin) { create(:user, :super_admin, company: company_a) }
  let(:regular_user) { create(:user, company: company_a) }
  let(:same_company_user) { create(:user, company: company_a) }
  let(:other_company_user) { create(:user, company: company_b) }
  let(:other_super_admin) { create(:user, :super_admin, company: company_b) }

  describe "#index?" do
    it "allows super admin" do
      expect(described_class.new(super_admin, User).index?).to be true
    end

    it "allows regular user" do
      expect(described_class.new(regular_user, User).index?).to be true
    end
  end

  describe "#show?" do
    it "allows super admin to view any user" do
      expect(described_class.new(super_admin, other_company_user).show?).to be true
    end

    it "allows user to view same company user" do
      expect(described_class.new(regular_user, same_company_user).show?).to be true
    end

    it "denies user from viewing other company user" do
      expect(described_class.new(regular_user, other_company_user).show?).to be false
    end

    it "allows user to view themselves" do
      expect(described_class.new(regular_user, regular_user).show?).to be true
    end
  end

  describe "#create?" do
    it "allows super admin" do
      expect(described_class.new(super_admin, User.new).create?).to be true
    end

    it "denies regular user" do
      expect(described_class.new(regular_user, User.new).create?).to be false
    end
  end

  describe "#update?" do
    it "allows super admin to update any user" do
      expect(described_class.new(super_admin, other_company_user).update?).to be true
    end

    it "allows super admin to update another super admin" do
      expect(described_class.new(super_admin, other_super_admin).update?).to be true
    end

    it "allows user to update their own record" do
      expect(described_class.new(regular_user, regular_user).update?).to be true
    end

    it "denies non-super-admin from updating a same-company peer" do
      expect(described_class.new(regular_user, same_company_user).update?).to be false
    end

    it "denies user from updating other company user" do
      expect(described_class.new(regular_user, other_company_user).update?).to be false
    end

    it "denies regular user from updating a super admin" do
      expect(described_class.new(regular_user, super_admin).update?).to be false
    end
  end

  describe "#destroy?" do
    it "denies deleting self for regular user" do
      expect(described_class.new(regular_user, regular_user).destroy?).to be false
    end

    it "denies deleting self for super admin" do
      expect(described_class.new(super_admin, super_admin).destroy?).to be false
    end

    it "allows super admin to delete regular user" do
      expect(described_class.new(super_admin, regular_user).destroy?).to be true
    end

    it "allows super admin to delete other company user" do
      expect(described_class.new(super_admin, other_company_user).destroy?).to be true
    end

    it "denies super admin from deleting another super admin" do
      expect(described_class.new(super_admin, other_super_admin).destroy?).to be false
    end

    it "denies regular user from deleting same company user" do
      expect(described_class.new(regular_user, same_company_user).destroy?).to be false
    end

    it "denies regular user from deleting other company user" do
      expect(described_class.new(regular_user, other_company_user).destroy?).to be false
    end

    it "denies regular user from deleting a super admin" do
      expect(described_class.new(regular_user, super_admin).destroy?).to be false
    end
  end

  describe "#impersonate?" do
    it "allows super admin to impersonate regular user" do
      expect(described_class.new(super_admin, regular_user).impersonate?).to be true
    end

    it "allows super admin to impersonate other company user" do
      expect(described_class.new(super_admin, other_company_user).impersonate?).to be true
    end

    it "denies super admin from impersonating another super admin" do
      expect(described_class.new(super_admin, other_super_admin).impersonate?).to be false
    end

    it "denies super admin from impersonating self" do
      expect(described_class.new(super_admin, super_admin).impersonate?).to be false
    end

    it "denies regular user from impersonating anyone" do
      expect(described_class.new(regular_user, same_company_user).impersonate?).to be false
      expect(described_class.new(regular_user, other_company_user).impersonate?).to be false
    end
  end

  describe "#manage_super_admin_flag?" do
    it "allows super admin" do
      expect(described_class.new(super_admin, regular_user).manage_super_admin_flag?).to be true
    end

    it "denies regular user" do
      expect(described_class.new(regular_user, same_company_user).manage_super_admin_flag?).to be false
    end
  end

  describe "#manage_company?" do
    it "allows super admin" do
      expect(described_class.new(super_admin, regular_user).manage_company?).to be true
    end

    it "denies regular user" do
      expect(described_class.new(regular_user, same_company_user).manage_company?).to be false
    end
  end

  describe "#see_company_column?" do
    it "allows super admin" do
      expect(described_class.new(super_admin, User).see_company_column?).to be true
    end

    it "denies regular user" do
      expect(described_class.new(regular_user, User).see_company_column?).to be false
    end
  end

  describe "#see_super_admin_column?" do
    it "allows super admin" do
      expect(described_class.new(super_admin, User).see_super_admin_column?).to be true
    end

    it "denies regular user" do
      expect(described_class.new(regular_user, User).see_super_admin_column?).to be false
    end
  end

  describe "Scope" do
    let!(:user_a1) { create(:user, company: company_a) }
    let!(:user_a2) { create(:user, company: company_a) }
    let!(:user_b1) { create(:user, company: company_b) }

    context "for super admin" do
      it "returns all users across companies" do
        scope = described_class::Scope.new(super_admin, User).resolve
        expect(scope).to include(user_a1, user_a2, user_b1, super_admin)
      end

      it "includes current_company association without error" do
        scope = described_class::Scope.new(super_admin, User).resolve
        expect { scope.map(&:current_company) }.not_to raise_error
      end
    end

    context "for regular user" do
      it "returns only same company users" do
        scope = described_class::Scope.new(regular_user, User).resolve
        expect(scope).to include(user_a1, user_a2, regular_user)
        expect(scope).not_to include(user_b1)
      end
    end
  end
end
