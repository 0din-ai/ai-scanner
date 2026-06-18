require 'rails_helper'

RSpec.describe 'admin/reports/_attempt_card.html.erb', type: :view do
  let(:report) { create(:report, :completed) }

  def render_card(attempt)
    render partial: 'admin/reports/attempt_card',
           locals: { attempt: attempt, index: 0, report: report, probe_result_id: 1 }
  end

  it 'renders Attack Successful for a succeeded attempt' do
    render_card({ 'prompt' => 'p', 'outputs' => [ 'o' ], 'notes' => {}, 'attack_succeeded' => true })
    expect(rendered).to include('Attack Successful')
    expect(rendered).not_to include('Blocked')
  end

  it 'renders Blocked for a defended attempt' do
    render_card({ 'prompt' => 'p', 'outputs' => [ 'o' ], 'notes' => {}, 'attack_succeeded' => false })
    expect(rendered).to include('Blocked')
    expect(rendered).not_to include('Attack Successful')
  end

  it 'renders the numeric score chip for a JEF attempt' do
    render_card({ 'prompt' => 'p', 'outputs' => [ 'o' ], 'notes' => { 'score_percentage' => '90.00%' }, 'attack_succeeded' => true })
    expect(rendered).to include('Score: 90.00%')
  end

  it 'renders no status badge for a legacy attempt missing attack_succeeded' do
    render_card({ 'prompt' => 'p', 'outputs' => [ 'o' ], 'notes' => {} })
    expect(rendered).not_to include('Attack Successful')
    expect(rendered).not_to include('Blocked')
  end
end
