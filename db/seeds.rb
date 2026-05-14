# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# =============================================================================
# Company & Admin User
# =============================================================================
# Creates the default organization and a super admin user.
# Idempotent - safe to run multiple times.

company = Company.find_or_create_by!(slug: "default-organization") do |c|
  c.name = "Default Organization"
  c.tier = :tier_1
end

admin_email = ENV.fetch("ADMIN_EMAIL", "admin@example.com")

admin = User.find_or_initialize_by(email: admin_email)
if admin.new_record?
  admin.password = admin.password_confirmation =
    ENV.fetch("ADMIN_INITIAL_PASSWORD") do
      unless Rails.env.development? || Rails.env.test?
        raise "ADMIN_INITIAL_PASSWORD must be set to seed the initial admin user outside development and test"
      end

      "password"
    end
end
admin.super_admin = true
admin.company = company
admin.time_zone = "UTC"
admin.save!

puts " Company: #{company.name}"
puts " Admin: #{admin.email}"

# =============================================================================
# Global Configuration
# =============================================================================

ActsAsTenant.with_tenant(company) do
  EnvironmentVariable.global.find_or_create_by(env_name: "EVALUATION_THRESHOLD") do |env|
    env.env_value = "0.2"
  end
end

Metadatum.find_or_create_by(key: 'parallel_scans_limit') do |m|
  m.value = '5'
end
