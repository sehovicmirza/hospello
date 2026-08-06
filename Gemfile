source "https://rubygems.org"

gem "rails", "~> 8.0.5", ">= 8.0.5.1"
gem "propshaft"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"

# Hotwire — no Node build chain
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "tailwindcss-rails"

gem "bcrypt", "~> 3.1.7"

gem "tzinfo-data", platforms: %i[ windows jruby ]

# Database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

gem "bootsnap", require: false

# Active Storage variants (hotel logos / welcome images)
gem "image_processing", "~> 1.2"
gem "aws-sdk-s3", require: false # Cloudflare R2 (S3-compatible)

# Multi-tenancy — fails closed: unscoped queries raise
gem "acts_as_tenant"

# Authorization
gem "pundit"

# AI concierge + translation
gem "anthropic"

# Guest QR codes (one per hotel)
gem "rqrcode"

# Abuse protection on public guest endpoints
gem "rack-attack"

# Phone normalization (optional guest phone, WhatsApp routing)
gem "phonelib"

# Locale data for guest chrome + staff UI
gem "rails-i18n"

# Ops
gem "sentry-ruby"
gem "sentry-rails"
gem "lograge"
gem "mission_control-jobs"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "brakeman", require: false
  gem "bundler-audit", require: false
  gem "rubocop-rails-omakase", require: false
  gem "dotenv-rails"
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
  gem "webmock"
end
