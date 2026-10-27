# Release images supply APP_VERSION; source builds must not claim a release version.
Rails.application.config.version = ENV["APP_VERSION"].to_s.strip.presence || "development"
