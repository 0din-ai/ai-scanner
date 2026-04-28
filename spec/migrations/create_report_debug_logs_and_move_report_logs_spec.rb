# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260427000000_create_report_debug_logs_and_move_report_logs")

RSpec.describe CreateReportDebugLogsAndMoveReportLogs do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    restore_current_schema
    example.run
  ensure
    restore_current_schema
  end

  it "backfills nonblank reports.logs and restores them on rollback" do
    report_with_logs = create(:report)
    blank_report = create(:report)
    whitespace_report = create(:report)

    migrate_down

    update_report_logs(report_with_logs.id, "legacy log line")
    update_report_logs(blank_report.id, "")
    update_report_logs(whitespace_report.id, "   ")

    migrate_up

    expect(connection.column_exists?(:reports, :logs)).to be(false)
    expect(moved_report_logs).to eq(report_with_logs.id => "legacy log line")

    migrate_down

    expect(connection.column_exists?(:reports, :logs)).to be(true)
    expect(report_logs(report_with_logs.id)).to eq("legacy log line")
    expect(report_logs(blank_report.id)).to be_nil
    expect(report_logs(whitespace_report.id)).to be_nil
  end

  it "keeps Report#logs compatible while the legacy column still exists" do
    report = create(:report)

    migrate_down
    update_report_logs(report.id, "legacy only")
    Report.reset_column_information

    expect(report.reload.logs).to eq("legacy only")
  end

  private

  def moved_report_logs
    connection.select_rows(<<~SQL.squish).to_h
      SELECT report_id, logs
      FROM report_debug_logs
      ORDER BY report_id
    SQL
  end

  def report_logs(report_id)
    connection.select_value("SELECT logs FROM reports WHERE id = #{report_id}")
  end

  def update_report_logs(report_id, logs)
    connection.execute(<<~SQL.squish)
      UPDATE reports
      SET logs = #{connection.quote(logs)}
      WHERE id = #{report_id}
    SQL
  end

  def migrate_down
    return if connection.column_exists?(:reports, :logs) && !connection.table_exists?(:report_debug_logs)

    ActiveRecord::Migration.suppress_messages { migration.down }
    reset_schema_cache
  end

  def migrate_up
    return if current_schema?

    ActiveRecord::Migration.suppress_messages { migration.up }
    reset_schema_cache
  end

  def restore_current_schema
    reset_schema_cache

    if !connection.table_exists?(:report_debug_logs)
      migrate_up
    elsif connection.column_exists?(:reports, :logs)
      connection.remove_column(:reports, :logs)
      reset_schema_cache
    end
  end

  def current_schema?
    connection.table_exists?(:report_debug_logs) && !connection.column_exists?(:reports, :logs)
  end

  def reset_schema_cache
    connection.schema_cache.clear!
    Report.reset_column_information
    ReportDebugLog.reset_column_information if connection.table_exists?(:report_debug_logs)
  end
end
