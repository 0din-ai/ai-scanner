# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'application/_system_status', type: :view do
  let(:company) { create(:company) }
  let(:target) { create(:target, company: company) }
  let(:scan) { create(:complete_scan, company: company) }

  before do
    allow_any_instance_of(RunGarakScan).to receive(:call)
    allow_any_instance_of(ToastNotifier).to receive(:call)
    allow(SettingsService).to receive(:parallel_scans_limit).and_return(20)
    Rails.cache.delete("running_scans_stats:#{company.id}")
    Rails.cache.delete('running_scans_stats:global')
  end

  it 'shows live running report counts when the stats cache is empty' do
    create(:report, target: target, scan: scan, status: :running, company: company)

    render partial: 'application/system_status', locals: { company_id: company.id, is_super_admin: true }

    expect(rendered).to include('Reports Running')
    expect(rendered).to include('System Total')
    expect(company_badge_text).to eq('1')
    expect(global_badge_text).to eq('1/20')
  end

  it 'uses the database as the source of truth instead of cached stats on initial render' do
    create(:report, target: target, scan: scan, status: :running, company: company)
    allow(Rails.cache).to receive(:fetch).and_raise('system status initial render must not depend on cached stats')
    allow(Rails.cache).to receive(:read).and_raise('system status initial render must not depend on cached stats')

    render partial: 'application/system_status', locals: { company_id: company.id, is_super_admin: true }

    expect(company_badge_text).to eq('1')
    expect(global_badge_text).to eq('1/20')
  end

  def company_badge_text
    Nokogiri::HTML.fragment(rendered).at_css('#system-status-company .inline-flex').text.squish
  end

  def global_badge_text
    Nokogiri::HTML.fragment(rendered).at_css('#system-status-global .inline-flex').text.squish
  end
end
