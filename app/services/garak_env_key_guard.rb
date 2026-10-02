# frozen_string_literal: true

# A target's generator config can name an environment variable for garak to read
# its API key from (`key_env_var`, honoured by garak's RestGenerator among others).
# garak then sends that variable's VALUE to the target's own URI as `$KEY`. The
# garak subprocess inherits the whole worker environment plus everything
# RunGarakScan#build_env sets, so an unchecked name lets any target author send
# deployment secrets (DATABASE_URL, shared provider keys, Rails secrets) to an
# endpoint they control.
#
# A referenced name is allowed only when the value garak would read is one the
# tenant supplied themselves: an EnvironmentVariable row of this tenant/target, and
# not a name the launcher overwrites with a deployment value.
class GarakEnvKeyGuard
  # key_env_var, client_key_passphrase_env_var, model_name_env_var, endpoint_env_var,
  # ENV_VAR...: garak getenv's every one of these across its generators.
  ENV_KEY_PARAMS = /(?:\A|_)env_var\z/i

  # Names RunGarakScan#build_env / ValidateTarget#build_env assign from deployment
  # state after merging the tenant's rows. A tenant row with one of these names does
  # not make the deployment value theirs. spec/services/garak_env_key_guard_spec.rb
  # fails if build_env starts setting a name this list does not cover.
  RESERVED_NAMES = %w[
    HOME DATABASE_URL LOG_FILE_PATH REPORT_UUID VARIANT_SCAN
    SCAN_EXECUTION_TOKEN SCAN_ID SCAN_NAME TARGET_ID TARGET_NAME
  ].freeze
  RESERVED_PREFIXES = %w[JUDGE_].freeze

  def self.reserved?(name)
    RESERVED_NAMES.include?(name) || GarakSubprocessEnv::INHERITED_NAMES.include?(name) ||
      RESERVED_PREFIXES.any? { |prefix| name.start_with?(prefix) }
  end

  # Every env-var name the config asks garak to read, at any nesting depth.
  def self.referenced_names(json_config)
    data = json_config.is_a?(String) ? JSON.parse(json_config) : json_config
    collect(data, [])
  rescue JSON::ParserError
    []
  end

  # Referenced names the tenant may not use. +tenant_env+ is the merged tenant/target
  # EnvironmentVariable rows (name => value).
  def self.violations(json_config, tenant_env)
    referenced_names(json_config).uniq.reject do |name|
      tenant_env.key?(name) && !reserved?(name)
    end
  end

  def self.rejection_message(names)
    "Target configuration references environment variable#{'s' if names.size > 1} " \
      "#{names.map { |n| n.to_s.truncate(64) }.join(', ')}, which #{names.size > 1 ? 'are' : 'is'} not one of this " \
      "workspace's own environment variables. Add it under Environment Variables, or remove key_env_var, " \
      "then revalidate the target."
  end

  # Generator options sit at most two levels down: {family: {Class: {params}}},
  # {"family.Class": {params}} or flat. Anything deeper (req_template_json_object,
  # headers, payload fields) is request data garak sends verbatim, never resolves
  # from the environment, so a literal "env_var" there is not a reference.
  OPTIONS_MAX_DEPTH = 2

  def self.collect(node, found, depth = 0)
    return found if depth > OPTIONS_MAX_DEPTH

    case node
    when Hash
      node.each do |key, value|
        found << value if key.to_s.match?(ENV_KEY_PARAMS) && value.is_a?(String) && value.present?
        collect(value, found, depth + 1) if value.is_a?(Hash)
      end
    end
    found
  end
  private_class_method :collect
end
