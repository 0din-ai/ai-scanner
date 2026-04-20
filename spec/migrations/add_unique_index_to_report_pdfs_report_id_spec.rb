require "rails_helper"
require Rails.root.join("db/migrate/20260418193602_add_unique_index_to_report_pdfs_report_id")

RSpec.describe AddUniqueIndexToReportPdfsReportId do
  let(:migration) { described_class.new }
  let(:conn) { ActiveRecord::Base.connection }

  def insert_report_pdf(report_id:, status:, file_path: nil)
    now = Time.current.utc.iso8601
    path_sql = file_path.nil? ? "NULL" : "'#{conn.quote_string(file_path)}'"
    conn.execute(<<~SQL)
      INSERT INTO report_pdfs (report_id, status, file_path, created_at, updated_at)
      VALUES (#{report_id}, #{status}, #{path_sql}, '#{now}', '#{now}')
    SQL
    conn.execute(
      "SELECT id FROM report_pdfs WHERE report_id = #{report_id} ORDER BY id DESC LIMIT 1"
    ).first["id"]
  end

  describe "migration safety" do
    it "runs inside the default DDL transaction so cleanup+uniqueness are atomic" do
      expect(described_class.disable_ddl_transaction).to be_falsey
    end
  end

  describe "#up idempotency" do
    it "is a no-op when the unique index already exists" do
      expect(conn.index_exists?(:report_pdfs, :report_id,
                                name: "index_report_pdfs_on_report_id", unique: true)).to be true

      expect { migration.up }.not_to raise_error
    end
  end

  context "real upgrade path from a non-unique index with duplicate data" do
    around do |example|
      conn.remove_index :report_pdfs, name: "index_report_pdfs_on_report_id", if_exists: true
      conn.add_index :report_pdfs, :report_id, name: "index_report_pdfs_on_report_id"
      example.run
    ensure
      conn.remove_index :report_pdfs, name: "index_report_pdfs_on_report_id", if_exists: true
      conn.add_index :report_pdfs, :report_id, unique: true, name: "index_report_pdfs_on_report_id"
    end

    it "collapses duplicates to the best row and installs the unique index in one pass" do
      report = create(:report)

      good_id = insert_report_pdf(report_id: report.id, status: 2, file_path: "/tmp/good.pdf")
      insert_report_pdf(report_id: report.id, status: 0) # later pending retry
      insert_report_pdf(report_id: report.id, status: 3) # even-later failed row

      expect(ReportPdf.where(report_id: report.id).count).to eq(3)

      migration.up

      remaining = ReportPdf.where(report_id: report.id)
      expect(remaining.pluck(:id)).to eq([ good_id ])

      expect(conn.index_exists?(:report_pdfs, :report_id,
                                name: "index_report_pdfs_on_report_id", unique: true)).to be true

      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          insert_report_pdf(report_id: report.id, status: 0)
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "#cleanup_duplicate_report_pdfs survivor policy" do
    around do |example|
      conn.remove_index :report_pdfs, name: "index_report_pdfs_on_report_id", if_exists: true
      conn.add_index :report_pdfs, :report_id, name: "index_report_pdfs_on_report_id"
      example.run
    ensure
      conn.remove_index :report_pdfs, name: "index_report_pdfs_on_report_id", if_exists: true
      conn.add_index :report_pdfs, :report_id, unique: true, name: "index_report_pdfs_on_report_id"
    end

    it "keeps the completed+file_path row even when a later pending/failed row exists" do
      report = create(:report)

      completed_id = insert_report_pdf(report_id: report.id, status: 2, file_path: "/tmp/report.pdf")
      insert_report_pdf(report_id: report.id, status: 0)
      insert_report_pdf(report_id: report.id, status: 3)

      migration.send(:cleanup_duplicate_report_pdfs)

      expect(ReportPdf.where(report_id: report.id).pluck(:id)).to eq([ completed_id ])
    end

    it "prefers a row with a file_path over rows without one when none is completed" do
      report = create(:report)

      with_file_id = insert_report_pdf(report_id: report.id, status: 1, file_path: "/tmp/processing.pdf")
      insert_report_pdf(report_id: report.id, status: 0)

      migration.send(:cleanup_duplicate_report_pdfs)

      expect(ReportPdf.where(report_id: report.id).pluck(:id)).to eq([ with_file_id ])
    end

    it "prefers a completed row without file_path over other non-file rows" do
      report = create(:report)

      completed_id = insert_report_pdf(report_id: report.id, status: 2)
      insert_report_pdf(report_id: report.id, status: 0)
      insert_report_pdf(report_id: report.id, status: 3)

      migration.send(:cleanup_duplicate_report_pdfs)

      expect(ReportPdf.where(report_id: report.id).pluck(:id)).to eq([ completed_id ])
    end

    it "falls back to the newest id when no row has file_path or completed status" do
      report = create(:report)

      insert_report_pdf(report_id: report.id, status: 0)
      insert_report_pdf(report_id: report.id, status: 3)
      newest_id = insert_report_pdf(report_id: report.id, status: 0)

      migration.send(:cleanup_duplicate_report_pdfs)

      expect(ReportPdf.where(report_id: report.id).pluck(:id)).to eq([ newest_id ])
    end

    it "treats an empty-string file_path as no file" do
      report = create(:report)

      completed_no_file_id = insert_report_pdf(report_id: report.id, status: 2, file_path: "")
      insert_report_pdf(report_id: report.id, status: 0)

      migration.send(:cleanup_duplicate_report_pdfs)

      expect(ReportPdf.where(report_id: report.id).pluck(:id)).to eq([ completed_no_file_id ])
    end

    it "does not remove non-duplicate report_pdfs" do
      report_a = create(:report)
      report_b = create(:report)

      insert_report_pdf(report_id: report_a.id, status: 0)
      insert_report_pdf(report_id: report_b.id, status: 0)

      migration.send(:cleanup_duplicate_report_pdfs)

      expect(ReportPdf.where(report_id: report_a.id).count).to eq(1)
      expect(ReportPdf.where(report_id: report_b.id).count).to eq(1)
    end
  end

  describe "resulting schema" do
    it "enforces uniqueness on report_pdfs.report_id" do
      report = create(:report)

      insert_report_pdf(report_id: report.id, status: 0)

      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          insert_report_pdf(report_id: report.id, status: 0)
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
