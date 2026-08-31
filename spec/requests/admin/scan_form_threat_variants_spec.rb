# frozen_string_literal: true

require "rails_helper"

# The scan form's variant picker renders one checkbox per subindustry, each
# carrying the probe ids it selects. Those ids are all the form needs, so it
# must not pay to load the variant rows or their probes to produce them.
RSpec.describe "New scan form threat variants", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, :super_admin, company: company) }

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  def build_variants(industry_name, subindustries: 2, variants_each: 2)
    industry = create(:threat_variant_industry, name: industry_name)
    subindustries.times.map do |i|
      sub = create(:threat_variant_subindustry, threat_variant_industry: industry,
                   name: "#{industry_name}-sub-#{i}")
      variants_each.times do |j|
        create(:threat_variant, threat_variant_subindustry: sub,
               probe: create(:probe), prompt: "#{industry_name} prompt #{i}-#{j}")
      end
      sub
    end
  end

  it "renders a checkbox per subindustry" do
    subs = build_variants("automotive")

    get new_scan_path

    expect(response).to have_http_status(:ok)
    subs.each { |sub| expect(response.body).to include("data-subindustry-id=\"#{sub.id}\"") }
  end

  it "does not render probe ids the page never reads" do
    # data-probe-ids was rendered on every industry and subindustry row and read
    # by nothing -- no Stimulus controller, no script, no test. Producing it was
    # the only reason the form loaded threat variants at all.
    build_variants("mining")

    get new_scan_path

    expect(response.body).not_to include("data-probe-ids")
  end

  it "does not load threat variant rows to render the picker" do
    # The picker renders names and checkboxes. Instantiating the variants -- and
    # the probes behind them -- is work whose result is thrown away.
    build_variants("energy", subindustries: 3, variants_each: 3)

    loaded = 0
    subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      loaded += payload[:record_count].to_i if payload[:class_name] == "ThreatVariant"
    end

    get new_scan_path

    ActiveSupport::Notifications.unsubscribe(subscriber)
    expect(loaded).to eq(0)
  end

  it "does not load the probes behind the variants either" do
    build_variants("aviation", subindustries: 2, variants_each: 2)

    loaded = 0
    subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      loaded += payload[:record_count].to_i if payload[:class_name] == "Probe"
    end

    get new_scan_path

    ActiveSupport::Notifications.unsubscribe(subscriber)
    # The probe list has its own section that legitimately loads probes, so this
    # asserts only that the variant picker adds none of its own.
    expect(loaded).to eq(Probe.count)
  end

  it "still renders a checkbox for a subindustry with no variants" do
    industry = create(:threat_variant_industry, name: "finance")
    empty = create(:threat_variant_subindustry, threat_variant_industry: industry, name: "empty")

    get new_scan_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-subindustry-id=\"#{empty.id}\"")
  end

  it "ticks the subindustries an existing scan already selected" do
    subs = build_variants("healthcare")
    scan = ActsAsTenant.with_tenant(company) do
      create(:complete_scan, company: company).tap { |s| s.threat_variant_subindustries = [ subs.first ] }
    end

    get edit_scan_path(scan)

    expect(response).to have_http_status(:ok)
    checked = response.body[/<input[^>]*value="#{subs.first.id}"[^>]*>/]
    expect(checked).to include("checked")
  end

  it "leaves the other subindustries unticked" do
    subs = build_variants("retail")
    scan = ActsAsTenant.with_tenant(company) do
      create(:complete_scan, company: company).tap { |s| s.threat_variant_subindustries = [ subs.first ] }
    end

    get edit_scan_path(scan)

    unchecked = response.body[/<input[^>]*value="#{subs.last.id}"[^>]*>/]
    expect(unchecked).not_to include("checked")
  end

  it "ticks nothing on a brand new scan" do
    build_variants("logistics")

    get new_scan_path

    expect(response.body.scan(/checked="checked"/).size).to eq(0)
  end
end
