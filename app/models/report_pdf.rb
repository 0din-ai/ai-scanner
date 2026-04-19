class ReportPdf < ApplicationRecord
  DOWNLOAD_GRACE_WINDOW = 2.minutes

  belongs_to :report

  enum :status, {
    pending: 0,
    processing: 1,
    completed: 2,
    failed: 3
  }, prefix: true

  validates :report, presence: true
  validates :report_id, uniqueness: true
  validates :status, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :stale, ->(hours = 24) { where("created_at < ?", hours.hours.ago) }

  # Check if PDF is ready to serve. A record is only ready when the persisted
  # file_path resolves inside the sandbox AND the file exists on disk — otherwise
  # the status endpoint could hand out a "ready" URL for a path the downloader
  # will reject with 404.
  def ready?
    status_completed? && safe_file_path.present?
  end

  def downloadable?
    ready? && (downloaded_at.nil? || downloaded_at > DOWNLOAD_GRACE_WINDOW.ago)
  end

  def claim_download!
    updated_count = self.class
      .where(id: id, downloaded_at: nil)
      .update_all(downloaded_at: Time.current, updated_at: Time.current)
    updated_count == 1
  end

  # Returns the sandbox-resolved absolute path when file_path points inside
  # storage/pdfs and the file exists, or nil otherwise.
  def safe_file_path
    return nil if file_path.blank?

    resolved = Reports::PdfStorage.safe_path(file_path)
    return nil unless resolved && File.exist?(resolved)

    resolved
  end

  # Get the file size in bytes
  def file_size
    path = safe_file_path
    return nil unless path

    File.size(path)
  end
end
