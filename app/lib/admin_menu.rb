# frozen_string_literal: true

# AdminMenu provides a menu system for the admin interface.
class AdminMenu
  MenuItem = Struct.new(:id, :label_text, :url_path, :icon_path, :priority, :subtitle, :children, :html_opts, keyword_init: true) do
    def label(_context = nil)
      label_text
    end

    def url(_context = nil)
      url_path
    end

    def icon
      icon_path
    end

    def html_options
      html_opts || {}
    end

    def items(_context = nil)
      children || []
    end

    def current?(controller_path, action_name = nil)
      return false if url_path.blank?

      # Check if the current path matches this menu item's URL
      path_without_params = url_path.split("?").first
      normalized_path = path_without_params.gsub(%r{^/}, "").gsub(%r{/$}, "")

      # Match against controller path (remove admin/ prefix for comparison)
      controller_match = controller_path.gsub("admin/", "")

      # Direct match or singular/plural match
      normalized_path == controller_match ||
        normalized_path == controller_match.singularize ||
        normalized_path == controller_match.pluralize ||
        (normalized_path.empty? && controller_match == "dashboard")
    end

    def url_matches?(request_path)
      return false if url_path.blank?

      # Normalize both paths for comparison
      normalized_url = url_path.split("?").first.gsub(%r{^/}, "").gsub(%r{/$}, "")
      normalized_request = request_path.gsub(%r{^/}, "").gsub(%r{/$}, "")

      normalized_url == normalized_request
    end
  end

  attr_reader :context

  class << self
    def build(context = nil)
      new(context)
    end
  end

  def initialize(context = nil)
    @context = context
  end

  def items(_context = nil)
    @items ||= build_menu_items
  end

  private

  def build_menu_items
    [
      MenuItem.new(
        id: "dashboard",
        label_text: "Dashboard",
        url_path: "/",
        icon_path: "menu/dashboard.svg",
        priority: 1
      ),
      MenuItem.new(
        id: "reports",
        label_text: "Reports",
        url_path: "/reports",
        icon_path: "menu/reports.svg",
        subtitle: "findings from each scan",
        priority: 4
      ),
      MenuItem.new(
        id: "targets",
        label_text: "Targets",
        url_path: "/targets",
        icon_path: "menu/targets.svg",
        subtitle: "the AI models you test",
        priority: 2
      ),
      MenuItem.new(
        id: "scans",
        label_text: "Scans",
        url_path: "/scans",
        icon_path: "menu/scans.svg",
        subtitle: "pick probes & attack a target",
        priority: 3
      ),
      MenuItem.new(
        id: "probes",
        label_text: "Probes",
        url_path: "/probes",
        icon_path: "menu/probes.svg",
        priority: 5
      ),
      MenuItem.new(
        id: "configuration",
        label_text: "Configuration",
        url_path: nil,
        icon_path: "menu/configuration.svg",
        priority: 6,
        children: [
          MenuItem.new(
            id: "config_env_vars",
            label_text: "Environment Variables",
            url_path: "/environment_variables",
            priority: 1
          ),
          (MenuItem.new(
            id: "config_integrations",
            label_text: "Integrations",
            url_path: "/integrations",
            priority: 2
          ) if show_integrations_menu?),
          (MenuItem.new(
            id: "config_settings",
            label_text: "Settings",
            url_path: "/settings",
            priority: 3
          ) if show_settings_menu?)
        ].compact
      ),
      MenuItem.new(
        id: "users",
        label_text: "Users",
        url_path: "/users",
        icon_path: "menu/users.svg",
        priority: 7
      ),
      MenuItem.new(
        id: "glossary",
        label_text: "Glossary",
        url_path: "/glossary",
        icon_path: "menu/glossary.svg",
        priority: 8
      ),
      # Companies menu - super admins only (via policy)
      companies_menu_item
    ].compact.sort_by(&:priority)
  end

  def companies_menu_item
    return nil unless show_companies_menu?

    MenuItem.new(
      id: "companies",
      label_text: "Companies",
      url_path: "/companies",
      icon_path: "menu/companies.svg",
      priority: 9
    )
  end

  def show_settings_menu?
    return false unless context&.respond_to?(:current_user)
    SettingsPolicy.new(context.current_user, :settings).show?
  end

  def show_integrations_menu?
    return false unless context&.respond_to?(:current_user)
    OutputServerPolicy.new(context.current_user, OutputServer).menu_visible?
  end

  def show_companies_menu?
    return false unless context&.respond_to?(:current_user)
    CompanyPolicy.new(context.current_user, Company).menu_visible?
  end
end
