# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'layouts/partials/_flash_messages', type: :view do
  it 'does not render internal flash markers like :timedout alongside the real message' do
    flash[:alert] = 'Your session expired. Please sign in again to continue.'
    flash[:timedout] = true

    render partial: 'layouts/partials/flash_messages'

    expect(alert_texts).to eq([ 'Your session expired. Please sign in again to continue.' ])
  end

  it 'renders every supported user-facing flash type' do
    flash[:notice] = 'Notice message'
    flash[:success] = 'Success message'
    flash[:alert] = 'Alert message'
    flash[:error] = 'Error message'
    flash[:warning] = 'Warning message'

    render partial: 'layouts/partials/flash_messages'

    expect(alert_texts).to contain_exactly(
      'Notice message', 'Success message', 'Alert message', 'Error message', 'Warning message'
    )
  end

  def alert_texts
    Nokogiri::HTML.fragment(rendered).css('[role="alert"]').map { |node| node.text.squish }
  end
end
