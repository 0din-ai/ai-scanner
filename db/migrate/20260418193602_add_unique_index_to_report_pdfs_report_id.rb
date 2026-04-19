class AddUniqueIndexToReportPdfsReportId < ActiveRecord::Migration[8.1]
  def up
    return if index_exists?(:report_pdfs, :report_id,
                            name: "index_report_pdfs_on_report_id", unique: true)

    cleanup_duplicate_report_pdfs

    remove_index :report_pdfs,
                 name: "index_report_pdfs_on_report_id",
                 if_exists: true
    add_index :report_pdfs, :report_id, unique: true,
              name: "index_report_pdfs_on_report_id"
  end

  def down
    remove_index :report_pdfs,
                 name: "index_report_pdfs_on_report_id",
                 if_exists: true
    add_index :report_pdfs, :report_id,
              name: "index_report_pdfs_on_report_id"
  end

  private

  # Survivor policy for duplicate report_pdfs rows, from best to worst:
  #   1. completed (status=2) with a non-empty file_path — the actual PDF
  #   2. any row with a non-empty file_path
  #   3. completed (status=2) without file_path
  #   4. highest id as a deterministic tiebreaker
  def cleanup_duplicate_report_pdfs
    duplicates = execute(<<~SQL).to_a
      SELECT report_id
      FROM report_pdfs
      GROUP BY report_id
      HAVING COUNT(*) > 1
    SQL

    return if duplicates.empty?

    say "Found #{duplicates.size} duplicate report_pdf groups — keeping best completed/file_path row per report_id"

    execute(<<~SQL)
      DELETE FROM report_pdfs
      WHERE id NOT IN (
        SELECT DISTINCT ON (report_id) id
        FROM report_pdfs
        ORDER BY
          report_id,
          CASE
            WHEN status = 2 AND file_path IS NOT NULL AND file_path <> '' THEN 0
            WHEN file_path IS NOT NULL AND file_path <> '' THEN 1
            WHEN status = 2 THEN 2
            ELSE 3
          END,
          id DESC
      )
    SQL
  end
end
