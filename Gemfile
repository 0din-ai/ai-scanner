source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
# json 3 turned JSON.parse's options into keywords, but Rails 8.1's
# ActiveSupport::JSON.decode still passes them positionally. The schema dumper
# then fails on every jsonb column with a default, db:migrate in the test env
# quietly drops those tables from db/schema.rb, and every RSpec run fails at
# boot. Lift this once Rails ships json-3 support.
gem "json", "< 3"
gem "rails", "~> 8.0"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use PostgreSQL as the database for Active Record
gem "pg", "~> 1.5"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", "~> 7.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "mission_control-jobs"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"


group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "mutex_m" # extracted from stdlib in Ruby 3.4+
  gem "ostruct" # extracted from stdlib in Ruby 3.5+

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
  gem "pry-rails"

  # RSpec for testing
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "faker"
  gem "shoulda-matchers"
  gem "database_cleaner-active_record"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  gem "simplecov", require: false
end

gem "devise"
gem "open3"
gem "cssbundling-rails", "~> 1.4"
gem "dotenv-rails"
gem "ice_cube"
gem "syslog_protocol", "~> 0.9.2"
gem "rubyzip"
gem "kramdown", "~> 2.5"
gem "ruby-openai", "~> 8.0"
gem "tiktoken_ruby"
gem "ransack" # Object-based searching
gem "pagy" # Pagination (faster and lighter than kaminari)
gem "acts_as_tenant" # Multi-tenancy scoping
gem "pundit" # Authorization policies

# To load a vendored engine, create a Gemfile.local with:
#   gem "my_engine", path: "engines/my_engine"

# Load local Gemfile overrides if present (useful for development)
eval_gemfile("Gemfile.local") if File.exist?(File.expand_path("Gemfile.local", __dir__))
