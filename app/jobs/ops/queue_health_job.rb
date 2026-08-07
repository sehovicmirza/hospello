module Ops
  # Runs from the queue every 10 minutes (config/recurring.yml) and reports
  # to Sentry when Solid Queue itself looks unhealthy: jobs piling up in
  # solid_queue_failed_executions, or the oldest unclaimed ready job sitting
  # long enough that a worker has plausibly stalled. Sentry.capture_message
  # is a safe no-op when SENTRY_DSN isn't configured (Sentry.initialized? is
  # false), so this job is inert in dev/test exactly like the rest of the
  # ops wiring — nothing here needs to check for the DSN itself.
  #
  # TenantFree: queue health is a platform-wide condition, not a hotel one.
  class QueueHealthJob < ApplicationJob
    include TenantFree

    queue_as :low

    STALE_READY_THRESHOLD = 5.minutes

    def perform
      failed_count = SolidQueue::FailedExecution.count
      oldest_ready_age = oldest_ready_job_age

      return unless failed_count > 0 || oldest_ready_age > STALE_READY_THRESHOLD

      Sentry.capture_message(
        "Solid Queue health check failed: #{failed_count} failed job(s), " \
        "oldest ready job #{oldest_ready_age.round}s old (threshold #{STALE_READY_THRESHOLD.to_i}s)",
        level: :error
      )
    end

    private
      def oldest_ready_job_age
        oldest = SolidQueue::ReadyExecution.order(:created_at).first
        return 0.seconds if oldest.nil?

        Time.current - oldest.created_at
      end
  end
end
