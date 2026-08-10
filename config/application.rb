require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Hospello
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # The four guest-facing languages (Slice 2's landing page, entry form,
    # and chat — see config/locales/guest.*.yml and GuestLocaleHelper).
    # Staff locales (Hotel::STAFF_LOCALES, User#locale) are bs/en, a subset
    # of this list, so nothing staff-facing is affected by widening it.
    config.i18n.available_locales = %i[bs en de ar]
    config.i18n.default_locale = :en
    # Falls back to :en (then stops — no further chain) for a key missing
    # from a locale's translation file, so a guest never sees a raw
    # "translation missing" string just because one phrase hasn't been
    # translated into their language yet.
    config.i18n.fallbacks = true
  end
end
