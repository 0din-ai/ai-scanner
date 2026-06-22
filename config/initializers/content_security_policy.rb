# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    policy.script_src  :self, :https
    policy.style_src   :self, :https, :unsafe_inline
    policy.base_uri    :self
    policy.frame_ancestors :self
    # policy.report_uri "/csp-violation-report-endpoint"
  end

  # Start REPORT-ONLY: the header is present and violations are reported, but nothing
  # is blocked — so a missed asset origin (importmap CDN, charts) cannot break the app.
  # Promote to enforcing (set this to false) after confirming no violations in prod.
  config.content_security_policy_report_only = true
end
