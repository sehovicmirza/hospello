module Ops
  # Confirms the whole background-job pipeline is alive, not just the web
  # process — see config/recurring.yml, which schedules this every 5 minutes.
  #
  # This has to run *from the queue* rather than from a web request (a
  # controller action polled by an external uptime monitor, say) or it would
  # miss exactly the failure it exists to catch. A live Puma process with a
  # dead Solid Queue supervisor still answers /up and looks perfectly healthy
  # to a web-facing check — but no job, including a web-triggered "ping"
  # job, would ever run again. Scheduling the ping as a recurring job makes
  # the queue pipeline itself responsible for sending it, so the pipeline has
  # to be alive for the monitor to hear anything at all. The monitor's own
  # "I haven't heard from you in N minutes" alert is what pages someone —
  # this job's only responsibility is to keep making noise while things are
  # fine.
  #
  # TenantFree: a dead queue is a platform-wide condition, not a hotel one.
  class HeartbeatJob < ApplicationJob
    include TenantFree

    queue_as :low

    # A heartbeat that takes more than a few seconds has already failed —
    # Net::HTTP's own defaults (60s open + 60s read) would otherwise let one
    # hung HEARTBEAT_URL occupy one of only two threads shared by the
    # default/low queues (config/queue.yml) for up to ~2 minutes per run,
    # every 5 minutes, degrading Ops::QueueHealthJob and the finished-jobs
    # cleanup alongside it before the rescue below ever gets a chance to log
    # and move on.
    HTTP_TIMEOUT = 5 # seconds

    def perform
      url = ENV["HEARTBEAT_URL"].presence
      return if url.blank? # No monitor configured — must never break a deploy.

      begin
        uri = URI.parse(url)
        Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT
        ) { |http| http.get(uri.request_uri) }
      rescue StandardError => e
        # A failed ping must not raise: that would retry the job and spam
        # Solid Queue's failed_executions table for what is, from the app's
        # perspective, someone else's outage. The monitor itself is what
        # notices a run of silence and pages — this job just logs and moves on.
        Rails.logger.error("Ops::HeartbeatJob failed to reach #{url}: #{e.class}: #{e.message}")
      end
    end
  end
end
