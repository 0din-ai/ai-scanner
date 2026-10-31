# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scan form agent fuzzing", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, :super_admin, company: company) }

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end


  it "persists the agent fuzzing flag" do
    target = create(:target, :good, company: company)
    probe = create(:probe)

    post scans_path, params: {
      scan: {
        name: "Agent fuzz",
        target_ids: [ target.id ],
        probe_ids: [ probe.id ],
        agent_fuzzing: "1"
      }
    }

    expect(Scan.last.agent_fuzzing).to be true
  end
end
