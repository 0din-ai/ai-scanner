class AddDownloadedAtToReportPdfs < ActiveRecord::Migration[8.1]
  def change
    add_column :report_pdfs, :downloaded_at, :datetime
    add_index :report_pdfs, :downloaded_at
  end
end
