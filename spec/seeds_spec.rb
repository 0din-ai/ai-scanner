require 'rails_helper'

RSpec.describe "Seeds", type: :feature do
  describe "Company and User seeding" do
    context "when database is empty" do
      before do
        User.destroy_all
        Company.destroy_all
      end

      it "creates one company" do
        expect { load Rails.root.join('db', 'seeds.rb') }.to change(Company, :count).by(1)

        expect(Company.find_by(slug: "default-organization")).to have_attributes(tier: "tier_1")
      end

      it "creates one admin user" do
        expect { load Rails.root.join('db', 'seeds.rb') }.to change(User, :count).by(1)
      end

      it "creates a super admin user in the default company" do
        load Rails.root.join('db', 'seeds.rb')

        admin = User.find_by(email: 'admin@example.com')
        expect(admin).to be_present
        expect(admin.super_admin?).to be true
        expect(admin.valid_password?('password')).to be true
        expect(admin.company.slug).to eq("default-organization")
        expect(admin.companies).to contain_exactly(admin.company)
        expect(admin.time_zone).to eq("UTC")
      end
    end

    context "outside development and test without an explicit initial password" do
      around do |example|
        original_password = ENV["ADMIN_INITIAL_PASSWORD"]
        ENV.delete("ADMIN_INITIAL_PASSWORD")

        example.run
      ensure
        if original_password.nil?
          ENV.delete("ADMIN_INITIAL_PASSWORD")
        else
          ENV["ADMIN_INITIAL_PASSWORD"] = original_password
        end
      end

      before do
        User.destroy_all
        Company.destroy_all
        allow(Rails.env).to receive(:development?).and_return(false)
        allow(Rails.env).to receive(:test?).and_return(false)
      end

      it "requires ADMIN_INITIAL_PASSWORD instead of using the development default" do
        expect { load Rails.root.join('db', 'seeds.rb') }
          .to raise_error(RuntimeError, /ADMIN_INITIAL_PASSWORD/)
      end
    end

    context "when companies and users already exist" do
      before do
        load Rails.root.join('db', 'seeds.rb')
      end

      it "does not create duplicate companies" do
        expect { load Rails.root.join('db', 'seeds.rb') }.not_to change(Company, :count)
      end

      it "does not create duplicate users" do
        expect { load Rails.root.join('db', 'seeds.rb') }.not_to change(User, :count)
      end

      it "preserves changed active company, intentional memberships, and time zone on restart" do
        admin = User.find_by!(email: 'admin@example.com')
        companies = create_list(:company, 2)
        admin.companies = companies
        admin.update!(current_company: companies.last, time_zone: "Madrid")

        expect { load Rails.root.join('db', 'seeds.rb') }.not_to change(Membership, :count)

        expect(admin.reload.current_company).to eq(companies.last)
        expect(admin.companies).to contain_exactly(*companies)
        expect(admin.time_zone).to eq("Madrid")
        expect(admin.super_admin?).to be true
      end

      it "preserves the existing password even when a different initial password is configured" do
        admin = User.find_by!(email: 'admin@example.com')
        admin.update!(password: "changed-password123", password_confirmation: "changed-password123")
        encrypted_password = admin.encrypted_password
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("ADMIN_INITIAL_PASSWORD").and_return("different-initial-password")

        load Rails.root.join('db', 'seeds.rb')

        expect(admin.reload.encrypted_password).to eq(encrypted_password)
        expect(admin.valid_password?("changed-password123")).to be true
      end

      it "repairs a missing active-company membership without dropping other memberships" do
        admin = User.find_by!(email: 'admin@example.com')
        active_company = create(:company)
        original_company = admin.current_company
        admin.update!(current_company: active_company)
        expect(admin.companies).not_to include(active_company)

        expect { load Rails.root.join('db', 'seeds.rb') }.to change(Membership, :count).by(1)

        expect(admin.reload.current_company).to eq(active_company)
        expect(admin.companies).to contain_exactly(original_company, active_company)
      end
    end

    context "when a configured legacy admin has no active company" do
      let(:admin) { build(:user, email: "configured-admin@example.com", time_zone: nil) }

      before do
        admin.save!
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("ADMIN_EMAIL", "admin@example.com").and_return(admin.email)
      end

      it "uses an existing membership before the default organization" do
        existing_company = create(:company)
        create(:membership, user: admin, company: existing_company)

        load Rails.root.join('db', 'seeds.rb')

        expect(admin.reload.current_company).to eq(existing_company)
        expect(admin.companies).to contain_exactly(existing_company)
        expect(admin.time_zone).to eq("UTC")
        expect(admin.super_admin?).to be true
      end

      it "assigns the default organization when no current company or memberships exist" do
        expect(admin.memberships).to be_empty

        load Rails.root.join('db', 'seeds.rb')

        expect(admin.reload.current_company.slug).to eq("default-organization")
        expect(admin.companies).to contain_exactly(admin.current_company)
        expect(admin.time_zone).to eq("UTC")
      end
    end

    context "when admin user exists but is not super admin" do
      before do
        Company.destroy_all
        User.destroy_all
        company = create(:company, slug: "default-organization", tier: :tier_1)
        create(:user, email: 'admin@example.com', super_admin: false, company: company)
      end

      it "updates admin user to be super admin" do
        admin = User.find_by(email: 'admin@example.com')
        expect(admin.super_admin?).to be false

        load Rails.root.join('db', 'seeds.rb')

        expect(admin.reload.super_admin?).to be true
      end
    end
  end

  describe "EnvironmentVariable seeding" do
    it "creates EVALUATION_THRESHOLD if it doesn't exist" do
      EnvironmentVariable.where(env_name: "EVALUATION_THRESHOLD").destroy_all

      expect { load Rails.root.join('db', 'seeds.rb') }.to change {
        EnvironmentVariable.where(env_name: "EVALUATION_THRESHOLD").count
      }.by(1)

      company = Company.find_by(slug: "default-organization")
      ActsAsTenant.with_tenant(company) do
        env_var = EnvironmentVariable.find_by(env_name: "EVALUATION_THRESHOLD")
        expect(env_var.env_value).to eq("0.2")
      end
    end

    it "doesn't duplicate existing environment variables" do
      load Rails.root.join('db', 'seeds.rb')

      expect { load Rails.root.join('db', 'seeds.rb') }.not_to change(EnvironmentVariable, :count)
    end
  end
end
