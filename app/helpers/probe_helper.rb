require "uri"

module ProbeHelper
  PROBE_LINK_CLASSES = "inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium bg-blue-100 text-blue-800 hover:bg-blue-200 dark:bg-blue-800 dark:!text-white dark:hover:bg-blue-700 transition-colors duration-200"
  PROBE_TECHNIQUE_LINK_CLASSES = "inline-flex items-center px-2 py-1 rounded-md text-xs font-medium border bg-orange-950/30 border-primary/30 text-primary hover:bg-orange-950/50 transition-colors mr-1 mb-1"
  # Community probe badge - styled to match new design system
  PROBE_COMMUNITY_BADGE_CLASSES = "inline-flex items-center px-2 py-1 rounded-md text-xs font-medium bg-teal-950 text-teal-400"
  ATTRIBUTION_URL_PATTERN = %r{https?://[^\s<>"']+}i.freeze

  PROBE_SIS_CLASSES = {
    1 => "bg-green-950/30 border-green-400/30 text-green-400",
    2 => "bg-blue-950/30 border-blue-400/30 text-blue-400",
    3 => "bg-yellow-950/30 border-yellow-400/30 text-yellow-400",
    4 => "bg-orange-950/30 border-primary/30 text-primary",
    5 => "bg-red-950/30 border-red-400/30 text-red-400"
  }.freeze

  PROBE_DISCLOSURE_CLASSES = {
    0 => "bg-purple-950 text-purple-400", # 0-day
    1 => "bg-zinc-800 text-zinc-400" # n-day
  }.freeze

  def probe_portal_url(guid)
    host = BrandConfig.host_url
    return nil unless host
    "#{host}/probes/#{guid}"
  end

  def probe_guid_link(probe)
    return unless probe&.guid
    url = probe_portal_url(probe.guid)
    return unless url

    link_to probe.short_guid, url, target: "_blank", class: PROBE_LINK_CLASSES
  end

  def probe_technique_link(technique)
    host = BrandConfig.host_url
    return unless host

    link_to technique.name, "#{host}/techniques/#{technique.path}", target: "_blank", class: PROBE_TECHNIQUE_LINK_CLASSES
  end

  def probe_social_impact_score_link(probe)
    return unless probe&.social_impact_score
    host = BrandConfig.host_url
    return unless host

    link_to probe.social_impact_score,
      "#{host}/social_impact_score#sis_level_#{probe.social_impact_score_before_type_cast}",
      target: "_blank",
      class: "inline-flex items-center px-2 py-1 rounded-md text-xs font-medium border #{PROBE_SIS_CLASSES[probe.social_impact_score_before_type_cast]} hover:opacity-80 transition-opacity"
  end

  def probe_disclosure_status_pill(probe)
    return unless probe&.disclosure_status

    content_tag(
      :span,
      probe.disclosure_status,
      class: "inline-flex items-center px-2 py-1 rounded-md text-xs font-medium #{PROBE_DISCLOSURE_CLASSES[probe.disclosure_status_before_type_cast]}"
    )
  end

  def probe_attribution(attribution)
    attribution_text = attribution.to_s
    candidate_url = attribution_text[ATTRIBUTION_URL_PATTERN]
    safe_attribution_url = sanitized_probe_attribution_url(candidate_url)

    return ERB::Util.html_escape(attribution_text) unless safe_attribution_url

    text = attribution_text.sub(candidate_url, "").strip.sub(/ - \z/, "")
    parts = []
    parts << ERB::Util.html_escape(text) if text.present?
    parts << "—" if text.present?
    parts << link_to(
      ERB::Util.html_escape(safe_attribution_url),
      safe_attribution_url,
      target: "_blank",
      rel: "noopener",
      class: "text-primary hover:text-primary/80"
    )

    safe_join(parts, " ")
  end

  # Display badge for community (garak) probes
  # @param probe [Probe] The probe object
  # @return [String, nil] HTML span with "Community" badge or nil for curated probes
  def probe_source_badge(probe)
    return unless probe&.source == "garak"

    content_tag(:span, "Community", class: PROBE_COMMUNITY_BADGE_CLASSES)
  end

  # Display probe name with disclosure status badge and optional source badge
  # @param probe [Probe] The probe object
  # @param link [Boolean] Whether to make the probe name a link (default: true)
  # @param link_class [String] CSS classes for the link (default: "text-sm text-primary hover:underline")
  # @return [String] HTML string with badge and probe name
  def probe_name_with_badge(probe, link: true, link_class: "text-sm text-primary hover:underline")
    content_tag(:div, class: "flex items-center gap-2 whitespace-nowrap") do
      safe_join([
        probe_disclosure_status_pill(probe),
        probe_source_badge(probe),
        if link
          link_to(probe.name, probe_path(probe), class: link_class)
        else
          content_tag(:span, probe.name, class: "text-sm text-contentPrimary")
        end
      ].compact)
    end
  end

  private

  def sanitized_probe_attribution_url(candidate_url)
    return if candidate_url.blank? || candidate_url.match?(/[[:cntrl:]]/)

    uri = URI.parse(candidate_url)
    return unless uri.is_a?(URI::HTTP)
    return unless uri.scheme.in?(%w[http https])
    return if uri.host.blank? || uri.userinfo.present?

    candidate_url
  rescue URI::InvalidURIError
    nil
  end
end
