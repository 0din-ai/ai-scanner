# frozen_string_literal: true

class CreateReportDebugLogsAndMoveReportLogs < ActiveRecord::Migration[8.1]
  def up
    create_table :report_debug_logs do |t|
      t.references :report, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.text :logs
      t.text :tail
      t.bigint :tail_offset, null: false, default: 0
      t.string :tail_digest
      t.datetime :tail_synced_at
      t.boolean :tail_truncated, null: false, default: false

      t.timestamps
    end

    backfill_report_logs if column_exists?(:reports, :logs)
    remove_column :reports, :logs if column_exists?(:reports, :logs)
  end

  def down
    add_column :reports, :logs, :text unless column_exists?(:reports, :logs)
    restore_report_logs if table_exists?(:report_debug_logs)
    drop_table :report_debug_logs if table_exists?(:report_debug_logs)
  end

  private

  def backfill_report_logs
    execute <<~SQL.squish
      INSERT INTO report_debug_logs (report_id, logs, created_at, updated_at)
      SELECT id, logs, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM reports
      WHERE logs IS NOT NULL AND BTRIM(logs) <> ''
    SQL
  end

  def restore_report_logs
    execute <<~SQL.squish
      UPDATE reports
      SET logs = report_debug_logs.logs
      FROM report_debug_logs
      WHERE report_debug_logs.report_id = reports.id
        AND report_debug_logs.logs IS NOT NULL
    SQL
  end
end
