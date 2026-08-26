# frozen_string_literal: true

require "rails_helper"

# A report is scored against ONE evaluation threshold. Processing used to re-resolve
# it from live config on every pass, so an edit to EVALUATION_THRESHOLD between launch
# and processing changed the verdict on a run that had already happened: garak's own
# passed count and the per-attempt success flags derived here disagreed over the same
# items, with nothing on screen saying why.
RSpec.describe Report, "evaluation threshold" do
  let(:company) { create(:company) }

  def with_global_threshold(value)
    ActsAsTenant.with_tenant(company) do
      EnvironmentVariable.create!(env_name: "EVALUATION_THRESHOLD", env_value: value, company: company)
    end
  end

  def build_report
    ActsAsTenant.with_tenant(company) { create(:report, company: company) }
  end

  describe "snapshot at creation" do
    it "records the threshold in force when the report is created" do
      with_global_threshold("0.2")

      expect(build_report.evaluation_threshold).to eq(0.2)
    end

    it "records the default when nothing overrides it" do
      expect(build_report.evaluation_threshold).to eq(EnvironmentVariable::GARAK_DEFAULT_EVAL_THRESHOLD)
    end

    it "leaves an explicitly supplied value alone" do
      with_global_threshold("0.2")

      report = ActsAsTenant.with_tenant(company) { create(:report, company: company, evaluation_threshold: 0.9) }

      expect(report.evaluation_threshold).to eq(0.9)
    end

    it "does not re-snapshot when the report is saved again" do
      report = build_report
      ActsAsTenant.with_tenant(company) do
        EnvironmentVariable.find_by(env_name: "EVALUATION_THRESHOLD")&.destroy
        EnvironmentVariable.create!(env_name: "EVALUATION_THRESHOLD", env_value: "0.9", company: company)
        report.update!(status: :running)
      end

      # A retry must re-launch under the SAME threshold. One report evaluating its
      # segments at different thresholds is the bug, not a case to model faithfully.
      expect(report.reload.evaluation_threshold).to eq(EnvironmentVariable::GARAK_DEFAULT_EVAL_THRESHOLD)
    end
  end

  describe "#pin_evaluation_threshold!" do
    it "returns the snapshot without rewriting it" do
      with_global_threshold("0.2")
      report = build_report

      ActsAsTenant.with_tenant(company) do
        EnvironmentVariable.find_by(env_name: "EVALUATION_THRESHOLD").update!(env_value: "0.9")
        expect(report.pin_evaluation_threshold!).to eq(0.2)
      end

      expect(report.reload.evaluation_threshold).to eq(0.2)
    end

    it "resolves and PERSISTS a legacy report that predates the column" do
      with_global_threshold("0.2")
      report = build_report
      Report.where(id: report.id).update_all(evaluation_threshold: nil)
      report.reload

      ActsAsTenant.with_tenant(company) { expect(report.pin_evaluation_threshold!).to eq(0.2) }

      # Persisting matters: without it, two processing passes over the same report
      # resolve live config independently and can disagree.
      expect(Report.where(id: report.id).pick(:evaluation_threshold)).to eq(0.2)
    end

    it "returns the value that WON, not the one this caller resolved" do
      report = build_report
      Report.where(id: report.id).update_all(evaluation_threshold: nil)
      report.reload
      with_global_threshold("0.2")

      # Another process pins first. The compare-and-set makes this caller's write a
      # no-op, and it must report the winner's value rather than its own.
      Report.where(id: report.id).update_all(evaluation_threshold: 0.7)

      ActsAsTenant.with_tenant(company) { expect(report.pin_evaluation_threshold!).to eq(0.7) }
    end

    it "does not overwrite other columns on this instance" do
      # A full reload would refresh execution_token too, so a launcher that lost the
      # race would pick up its replacement's token and claim its execution slot.
      report = build_report
      Report.where(id: report.id).update_all(evaluation_threshold: nil)
      report.reload
      token = SecureRandom.uuid
      report.execution_token = token
      Report.where(id: report.id).update_all(execution_token: SecureRandom.uuid)

      ActsAsTenant.with_tenant(company) { report.pin_evaluation_threshold! }

      expect(report.execution_token).to eq(token)
      expect(report.changed).not_to include("evaluation_threshold")
    end

    it "pins under the report's own tenant, whatever tenant is current" do
      # Report is acts_as_tenant, so a query written without a tenant block follows
      # the ambient one. Under a DIFFERENT tenant the update would match no row and
      # no-op, and the read-back would return nil and raise as though the report had
      # been deleted.
      with_global_threshold("0.2")
      report = build_report
      Report.where(id: report.id).update_all(evaluation_threshold: nil)
      report.reload
      other = create(:company)

      ActsAsTenant.with_tenant(other) { expect(report.pin_evaluation_threshold!).to eq(0.2) }

      expect(Report.unscoped.where(id: report.id).pick(:evaluation_threshold)).to eq(0.2)
    end

    it "raises when the row vanished mid-pin" do
      report = build_report
      Report.where(id: report.id).update_all(evaluation_threshold: nil)
      report.reload
      Report.where(id: report.id).delete_all

      expect { ActsAsTenant.with_tenant(company) { report.pin_evaluation_threshold! } }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "tenant resolution" do
    it "resolves under the report's own tenant, not the ambient one" do
      # The value lives in a per-tenant encrypted EnvironmentVariable. Resolving with
      # no tenant set decrypts nothing and returns 0.0 -- a threshold that makes every
      # numeric score a successful attack.
      with_global_threshold("0.2")

      report = ActsAsTenant.without_tenant { create(:report, company: company, target: create_target) }

      expect(report.evaluation_threshold).to eq(0.2)
    end

    def create_target
      ActsAsTenant.with_tenant(company) { create(:target, company: company) }
    end
  end
end
