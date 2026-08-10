require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Where hotel logos and welcome images live. Follows R2_BUCKET rather than
  # defaulting to either service outright: r2 without the R2_* variables set
  # does not degrade, it aborts boot (S3Service resolves the bucket eagerly,
  # so aws-sdk raises on a nil bucket name at initializer time) — but local
  # disk is ephemeral (uploads are lost on redeploy), so silently defaulting
  # to it would mean nobody ever gets durable storage just because
  # ACTIVE_STORAGE_SERVICE was left unset. This is durable the instant R2 is
  # configured and never boots broken when it isn't; ACTIVE_STORAGE_SERVICE
  # still overrides either way if that's ever needed.
  config.active_storage.service =
    ENV.fetch("ACTIVE_STORAGE_SERVICE") { ENV["R2_BUCKET"].present? ? "r2" : "local" }.to_sym

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # The public hostname guests reach — resolved, validated, and normalized
  # in exactly one place (AppHost) and exactly once, here at boot, so a
  # misconfigured or missing APP_HOST fails the deploy immediately instead
  # of two different ways: silently linking mail to a placeholder host, and
  # separately 500ing a printed QR code's page only when a receptionist
  # happens to click it (review round 1's "split failure policy" finding —
  # this replaced two independent ENV["APP_HOST"] reads with different
  # fallbacks). Staff::QrCodesController reads the same resolved value back
  # via config.x.app_host — see its #app_host.
  #
  # Deferred to config.after_initialize rather than called directly here:
  # AppHost is an app/services class, and Zeitwerk's main autoloader for
  # app/* isn't set up yet at the point this file loads (config/environments
  # config runs very early in Rails' boot sequence — see
  # Rails::Engine's :load_environment_config initializer — well before the
  # Finisher stage that sets up autoloading and eager loading).
  # after_initialize is the last step of boot, after both are done, so
  # AppHost is guaranteed to already be a loaded constant here.
  config.after_initialize do
    resolved_app_host = AppHost.resolve!
    config.x.app_host = resolved_app_host
    config.action_mailer.default_url_options = { host: resolved_app_host }
  end

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # Which upstream hops to trust when resolving a request's real IP from
  # X-Forwarded-For — read by ActionDispatch::RemoteIp (a default Rails
  # middleware) for the app generally, and read again, independently, by
  # Rack::Attack::Request#trusted_proxy? in config/initializers/rack_attack.rb
  # so every throttle's client-IP resolution follows this same single,
  # configured answer instead of Rack::Request's own separate, hardcoded one.
  #
  # force_ssl = true above confirms there's an SSL-terminating proxy in
  # front of Puma on Render — so trusting *something* here is necessary, not
  # optional; a request's REMOTE_ADDR as Puma sees it is that proxy, not the
  # guest. What's set here is Rails' own default trusted-proxy list
  # (loopback + the RFC1918 private ranges) — the same set Rails already
  # uses when this is left unset, made explicit so it's one deliberate,
  # documented decision instead of an implicit default nobody chose on
  # purpose. It is the standard assumption for a PaaS proxy that forwards
  # over an internal/private-range hop (this is how Heroku's routers present
  # themselves to a dyno, for instance) — stated plainly, *not yet verified*
  # against a live Render deployment, since doing that requires an actual
  # deployed instance to inspect. If that assumption is ever found wrong —
  # Render's edge presents via some other address — this is the one line to
  # extend (`+= [IPAddr.new("<confirmed address or range>")]`); nothing in
  # rack_attack.rb needs to change to pick it up.
  config.action_dispatch.trusted_proxies = ActionDispatch::RemoteIp::TRUSTED_PROXIES
end
