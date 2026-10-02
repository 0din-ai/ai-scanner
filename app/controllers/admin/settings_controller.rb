# frozen_string_literal: true

module Admin
  class SettingsController < Admin::BaseController
    def show
      authorize :settings, :show?
      @page_title = "Settings"
      @parallel_scans_limit = SettingsService.parallel_scans_limit
      @parallel_attempts = SettingsService.parallel_attempts
      @portal_token = SettingsService.portal_token if SettingsService.respond_to?(:portal_token)
      @custom_header_html = SettingsService.custom_header_html if policy(:settings).manage_super_admin_settings?
      @running_scans_count = (Rails.cache.read("running_scans_stats") || {})[:total] || Report.active.count
    end

    def update
      authorize :settings, :update?
      filtered = settings_params

      # Validate parallel_scans_limit
      if filtered[:parallel_scans_limit].present?
        limit = filtered[:parallel_scans_limit].to_i
        unless limit.between?(1, 20)
          redirect_to settings_path, alert: "Parallel scans limit must be between 1 and 20."
          return
        end
        SettingsService.set_parallel_scans_limit(limit)
      end

      # Validate parallel_attempts
      if filtered[:parallel_attempts].present?
        attempts = filtered[:parallel_attempts].to_i
        unless attempts.between?(1, 100)
          redirect_to settings_path, alert: "Parallel attempts must be between 1 and 100."
          return
        end
        SettingsService.set_parallel_attempts(attempts)
      end

      if filtered[:portal_token].present? && SettingsService.respond_to?(:set_portal_token)
        SettingsService.set_portal_token(filtered[:portal_token])
      end

      if filtered.key?(:custom_header_html)
        SettingsService.set_custom_header_html(filtered[:custom_header_html])
      end

      redirect_to settings_path, notice: "Settings saved successfully."
    rescue ArgumentError => e
      redirect_to settings_path, alert: e.message
    rescue StandardError => e
      raise if e.is_a?(Pundit::NotAuthorizedError)
      Rails.logger.error "Failed to save settings: #{e.message}"
      redirect_to settings_path, alert: "Failed to save settings. Please try again."
    end

    private

    def settings_params
      permitted = [ :parallel_scans_limit, :parallel_attempts ]
      if policy(:settings).manage_super_admin_settings?
        permitted << :portal_token if SettingsService.respond_to?(:set_portal_token)
        permitted << :custom_header_html
      end
      params.permit(permitted)
    end
  end
end
