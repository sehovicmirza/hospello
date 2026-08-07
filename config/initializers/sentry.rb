# Inert unless SENTRY_DSN is set (render.yaml lists it as optional) — a
# missing DSN must never break a deploy or a test run. Sentry.init is simply
# never called otherwise, and every Sentry.* call elsewhere in the app
# (Ops::QueueHealthJob, Rails' own error reporter integration) is a
# documented no-op when Sentry.initialized? is false.
if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]

    # Guest and staff request bodies can carry a guest's name, a phone
    # number, a room number — sentry-ruby's send_default_pii is already
    # false by default, but this restates the choice explicitly rather than
    # relying on an SDK default nobody here decided on purpose. With it
    # false, Sentry::Interfaces::Request never even reads POST params,
    # cookies, or the query string onto the event, and strips IP headers
    # from the captured Rack env outright — scrubbing by omission, not by
    # trying to enumerate every sensitive key after the fact.
    config.send_default_pii = false

    # 10% of transactions — enough to see p95/p99 latency trends on a
    # pilot's traffic without paying to trace every request.
    config.traces_sample_rate = 0.1
  end
end
