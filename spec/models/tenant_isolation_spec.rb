# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Tenant Isolation", type: :model do
  let(:company_a) { create(:company, name: "Company A") }
  let(:company_b) { create(:company, name: "Company B") }

  describe "Target" do
    let!(:target_a) { create(:target, company: company_a, name: "Target A") }
    let!(:target_b) { create(:target, company: company_b, name: "Target B") }

    it "scopes queries to current tenant" do
      ActsAsTenant.with_tenant(company_a) do
        expect(Target.all).to contain_exactly(target_a)
        expect(Target.all).not_to include(target_b)
      end
    end

    it "returns different results for different tenants" do
      ActsAsTenant.with_tenant(company_a) do
        expect(Target.count).to eq(1)
        expect(Target.first.name).to eq("Target A")
      end

      ActsAsTenant.with_tenant(company_b) do
        expect(Target.count).to eq(1)
        expect(Target.first.name).to eq("Target B")
      end
    end

    it "returns all records when no tenant is set" do
      ActsAsTenant.current_tenant = nil
      expect(Target.count).to eq(2)
      expect(Target.all).to include(target_a, target_b)
    end

    it "automatically assigns current tenant on create" do
      ActsAsTenant.with_tenant(company_a) do
        new_target = Target.create!(name: "New Target", model_type: "OpenAIGenerator", model: "gpt-4")
        expect(new_target.company).to eq(company_a)
      end
    end
  end

  describe "Scan" do
    let!(:target_a) { create(:target, company: company_a) }
    let!(:target_b) { create(:target, company: company_b) }
    let!(:probe) { create(:probe) }

    let!(:scan_a) do
      scan = build(:scan, company: company_a, name: "Scan A")
      scan.targets << target_a
      scan.probes << probe
      allow(scan).to receive(:update_next_scheduled_run)
      allow_any_instance_of(RunGarakScan).to receive(:call)
      scan.save!
      scan
    end

    let!(:scan_b) do
      scan = build(:scan, company: company_b, name: "Scan B")
      scan.targets << target_b
      scan.probes << probe
      allow(scan).to receive(:update_next_scheduled_run)
      allow_any_instance_of(RunGarakScan).to receive(:call)
      scan.save!
      scan
    end

    it "scopes queries to current tenant" do
      ActsAsTenant.with_tenant(company_a) do
        expect(Scan.all).to contain_exactly(scan_a)
        expect(Scan.all).not_to include(scan_b)
      end
    end

    it "returns different results for different tenants" do
      ActsAsTenant.with_tenant(company_a) do
        expect(Scan.count).to eq(1)
        expect(Scan.first.name).to eq("Scan A")
      end

      ActsAsTenant.with_tenant(company_b) do
        expect(Scan.count).to eq(1)
        expect(Scan.first.name).to eq("Scan B")
      end
    end
  end

  describe "Report" do
    let!(:target_a) { create(:target, company: company_a) }
    let!(:target_b) { create(:target, company: company_b) }
    let!(:scan_a) { create(:complete_scan, company: company_a) }
    let!(:scan_b) { create(:complete_scan, company: company_b) }

    let!(:report_a) { create(:report, company: company_a, scan: scan_a, target: target_a, name: "Report A") }
    let!(:report_b) { create(:report, company: company_b, scan: scan_b, target: target_b, name: "Report B") }

    it "scopes queries to current tenant" do
      ActsAsTenant.with_tenant(company_a) do
        expect(Report.all).to include(report_a)
        expect(Report.all).not_to include(report_b)
      end
    end

    it "returns different results for different tenants" do
      ActsAsTenant.with_tenant(company_a) do
        results = Report.where(name: [ "Report A", "Report B" ])
        expect(results).to include(report_a)
        expect(results).not_to include(report_b)
      end

      ActsAsTenant.with_tenant(company_b) do
        results = Report.where(name: [ "Report A", "Report B" ])
        expect(results).not_to include(report_a)
        expect(results).to include(report_b)
      end
    end
  end

  describe "OutputServer" do
    let!(:server_a) { create(:output_server, company: company_a, name: "Server A") }
    let!(:server_b) { create(:output_server, company: company_b, name: "Server B") }

    it "scopes queries to current tenant" do
      ActsAsTenant.with_tenant(company_a) do
        expect(OutputServer.all).to contain_exactly(server_a)
        expect(OutputServer.all).not_to include(server_b)
      end
    end

    it "returns different results for different tenants" do
      ActsAsTenant.with_tenant(company_a) do
        expect(OutputServer.count).to eq(1)
        expect(OutputServer.first.name).to eq("Server A")
      end

      ActsAsTenant.with_tenant(company_b) do
        expect(OutputServer.count).to eq(1)
        expect(OutputServer.first.name).to eq("Server B")
      end
    end
  end

  describe "cross-tenant prevention" do
    it "requires company to be present on Target" do
      target = Target.new(name: "Test", model_type: "test", model: "test")
      expect(target).not_to be_valid
      expect(target.errors[:company]).to include("must exist")
    end

    it "requires company to be present on Scan" do
      scan = Scan.new(name: "Test", uuid: SecureRandom.uuid)
      scan.probes = [ create(:probe) ]
      scan.targets = [ create(:target) ]
      allow(scan).to receive(:update_next_scheduled_run)
      expect(scan).not_to be_valid
      expect(scan.errors[:company]).to include("must exist")
    end

    it "requires company to be present on Report" do
      report = Report.new(name: "Test")
      expect(report).not_to be_valid
      expect(report.errors[:company]).to include("must exist")
    end

    it "requires company to be present on OutputServer" do
      server = OutputServer.new(name: "Test", host: "localhost", port: 8080)
      expect(server).not_to be_valid
      expect(server.errors[:company]).to include("must exist")
    end

    it "allows User without company (M:N relationship via memberships)" do
      user = User.new(email: "test@example.com", password: "password123")
      expect(user).to be_valid
    end
  end

  describe "nested associations" do
    let!(:target) { create(:target, company: company_a) }
    let!(:probe) { create(:probe) }

    before do
      allow_any_instance_of(RunGarakScan).to receive(:call)
    end

    it "creates reports with same company as scan" do
      scan = build(:scan, company: company_a)
      scan.targets << target
      scan.probes << probe
      allow(scan).to receive(:update_next_scheduled_run)
      scan.save!

      expect(scan.reports).to all(have_attributes(company: company_a))
    end
  end

  describe "scoped uniqueness" do
    it "allows same target name in different companies" do
      create(:target, company: company_a, name: "Shared Name")
      target_b = build(:target, company: company_b, name: "Shared Name")
      expect(target_b).to be_valid
    end

    it "prevents duplicate target name in same company" do
      create(:target, company: company_a, name: "Unique Name")
      duplicate = build(:target, company: company_a, name: "Unique Name")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end

    it "allows same output_server name in different companies" do
      create(:output_server, company: company_a, name: "Shared Server")
      server_b = build(:output_server, company: company_b, name: "Shared Server")
      expect(server_b).to be_valid
    end

    it "prevents duplicate output_server name in same company" do
      create(:output_server, company: company_a, name: "Unique Server")
      duplicate = build(:output_server, company: company_a, name: "Unique Server")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end
  end

  describe "finder methods respect tenant scope" do
    let!(:target_a) { create(:target, company: company_a) }
    let!(:target_b) { create(:target, company: company_b) }

    it "find_by respects tenant scope" do
      ActsAsTenant.with_tenant(company_a) do
        expect(Target.find_by(id: target_a.id)).to eq(target_a)
        expect(Target.find_by(id: target_b.id)).to be_nil
      end
    end

    it "exists? respects tenant scope" do
      ActsAsTenant.with_tenant(company_a) do
        expect(Target.exists?(target_a.id)).to be true
        expect(Target.exists?(target_b.id)).to be false
      end
    end

    it "where respects tenant scope" do
      ActsAsTenant.with_tenant(company_a) do
        results = Target.where(id: [ target_a.id, target_b.id ])
        expect(results).to contain_exactly(target_a)
      end
    end
  end

  # Security regression tests for soft-delete tenant isolation
  # Ensures soft-delete scopes preserve tenant isolation
  describe "Target.with_deleted tenant isolation" do
    let!(:target_a) { create(:target, company: company_a, name: "Target A") }
    let!(:deleted_target_a) { create(:target, company: company_a, name: "Deleted A", deleted_at: Time.current) }
    let!(:target_b) { create(:target, company: company_b, name: "Target B") }
    let!(:deleted_target_b) { create(:target, company: company_b, name: "Deleted B", deleted_at: Time.current) }

    describe ".with_deleted scope" do
      it "only returns targets from current tenant (active and deleted)" do
        ActsAsTenant.with_tenant(company_a) do
          results = Target.with_deleted
          expect(results).to include(target_a, deleted_target_a)
          expect(results).not_to include(target_b, deleted_target_b)
        end
      end

      it "cannot find other tenant's targets by ID" do
        ActsAsTenant.with_tenant(company_a) do
          expect { Target.with_deleted.find(target_b.id) }
            .to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      it "cannot find other tenant's deleted targets by ID" do
        ActsAsTenant.with_tenant(company_a) do
          expect { Target.with_deleted.find(deleted_target_b.id) }
            .to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      it "find_by returns nil for other tenant's deleted targets" do
        ActsAsTenant.with_tenant(company_a) do
          expect(Target.with_deleted.find_by(id: deleted_target_b.id)).to be_nil
        end
      end
    end

    describe ".deleted scope" do
      it "only returns deleted targets from current tenant" do
        ActsAsTenant.with_tenant(company_a) do
          results = Target.deleted
          expect(results).to include(deleted_target_a)
          expect(results).not_to include(target_a) # Not deleted
          expect(results).not_to include(deleted_target_b) # Wrong tenant
        end
      end

      it "cannot find other tenant's deleted targets by ID" do
        ActsAsTenant.with_tenant(company_a) do
          expect { Target.deleted.find(deleted_target_b.id) }
            .to raise_error(ActiveRecord::RecordNotFound)
        end
      end
    end

    describe "SQL query verification" do
      it "with_deleted includes company_id in WHERE clause" do
        ActsAsTenant.with_tenant(company_a) do
          sql = Target.with_deleted.to_sql
          expect(sql).to include("company_id")
        end
      end

      it "deleted includes company_id in WHERE clause" do
        ActsAsTenant.with_tenant(company_a) do
          sql = Target.deleted.to_sql
          expect(sql).to include("company_id")
        end
      end
    end
  end
end
