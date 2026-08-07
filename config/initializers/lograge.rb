# Production only: development and test keep Rails' normal multi-line log
# output (readable while debugging a single request; lograge's whole point
# is condensing each request to one line for a log aggregator, which is a
# production concern, not a local one).
if Rails.env.production?
  Rails.application.configure do
    config.lograge.enabled = true
    config.lograge.formatter = Lograge::Formatters::Json.new

    # hotel_id and user_id turn "which requests are slow/erroring" into
    # "which *hotel's* requests are slow/erroring" without joining log lines
    # back to a request id by hand; request_id is what makes that join
    # possible in the first place, tying a lograge line back to the matching
    # Sentry event and any other log lines tagged with the same id
    # (config.log_tags in config/environments/production.rb).
    config.lograge.custom_options = lambda do |event|
      {
        hotel_id: Current.hotel&.id,
        user_id: Current.user&.id,
        request_id: event.payload[:request]&.request_id
      }
    end
  end
end
