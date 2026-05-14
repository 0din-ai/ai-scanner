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
