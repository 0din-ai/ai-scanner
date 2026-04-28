require 'rails_helper'

RSpec.describe 'admin/reports/_logs_section', type: :view do
  it 'renders final logs through the Report#logs compatibility accessor' do
    report = create(:report, :completed)
    create(:report_debug_log, report: report,
           logs: "probes.test  test.detector: \e[1m\e[92mPASS\e[0m ok on  3/  3\nINFO final log line\n")

    render partial: 'admin/reports/logs_section', locals: { report: report, lease_url: '/reports/1/refresh_debug_lease' }

    expect(rendered).to include('report-activity-stream')
    expect(rendered).to include('data-controller="activity-stream"')
    expect(rendered).to include('report-activity-stream-details')
    expect(rendered).to include('aria-expanded="false"')
    expect(rendered).to include('View activity')
    expect(rendered).to include('Activity Stream')
    expect(rendered).to include('Execution Logs')
    expect(rendered).to include('Timeline')
    expect(rendered).to include('Raw JSONL')
    expect(rendered).to include('data-controller="debug-tabs debug-stream-filter"')
    expect(rendered).to include('data-action="click->debug-tabs#switch"')
    expect(rendered).to include('data-debug-tabs-target="tab"')
    expect(rendered).to include('data-debug-stream-filter-target="query"')
    expect(rendered).not_to include('click->report-redesigned#toggleLogs')
    expect(rendered).to include('report-activity-stream-summary')
    expect(rendered).to include('Final logs')
    expect(rendered).to include('final log line')
    expect(rendered).to include('2 execution log lines captured')
    expect(rendered).to include('Shown lines:')
    expect(rendered).not_to include('turbo-cable-stream-source')
    expect(rendered).not_to include('data-controller="debug-stream-lease"')
    expect(rendered).not_to include('data-debug-stream-lease-url-value="/reports/1/refresh_debug_lease"')
    expect(rendered).to include('<span class="font-bold text-green-400">PASS</span>').or include('font-bold text-red-400')
    expect(rendered).to include('<span class="text-orange-400">')
  end

  it 'mounts live Activity Stream wiring for active reports' do
    report = create(:report, :running)

    render partial: 'admin/reports/logs_section', locals: { report: report, lease_url: '/reports/1/refresh_debug_lease' }

    expect(rendered).to include('report-activity-stream')
    expect(rendered).to include('report-debug-stream-content')
    expect(rendered).to include('turbo-cable-stream-source')
    expect(rendered).to include('data-controller="debug-stream-lease"')
    expect(rendered).to include('data-debug-stream-lease-url-value="/reports/1/refresh_debug_lease"')
  end

  it 'renders live tail logs with metadata while a report is running' do
    report = create(:report, :running)
    create(
      :report_debug_log,
      report: report,
      tail: "first live line\nsecond live line\n",
      tail_offset: 2048,
      tail_digest: "tail-digest",
      tail_synced_at: 2.minutes.ago,
      tail_truncated: true
    )

    render partial: 'admin/reports/logs_section', locals: { report: report }

    expect(rendered).to include('LIVE')
    expect(rendered).to include('Live tail')
    expect(rendered).to include('Offset 2,048 bytes')
    expect(rendered).to include('Tail truncated')
    expect(rendered).to include('second live line')
  end

  it 'renders the empty state when no logs are available' do
    report = create(:report)

    render partial: 'admin/reports/logs_section', locals: { report: report }

    expect(rendered).to include('No logs available')
  end
end
