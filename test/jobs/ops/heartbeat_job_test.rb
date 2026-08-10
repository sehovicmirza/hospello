require "test_helper"

module Ops
  # HeartbeatJob's whole point is that it runs from the queue, not from a web
  # request — see the job for why. These tests only cover the HTTP contract:
  # it pings when configured, no-ops without raising on a blank URL (a
  # missing HEARTBEAT_URL must never break a deploy), and swallows — rather
  # than propagates — a failed ping.
  class HeartbeatJobTest < ActiveSupport::TestCase
    setup { @original_url = ENV["HEARTBEAT_URL"] }
    teardown { ENV["HEARTBEAT_URL"] = @original_url }

    test "pings the configured URL" do
      ENV["HEARTBEAT_URL"] = "https://heartbeat.example/ping/abc123"
      stub = stub_request(:get, "https://heartbeat.example/ping/abc123").to_return(status: 200)

      HeartbeatJob.perform_now

      assert_requested stub
    end

    # Not just "no HTTP call and no raised exception": URI.parse(nil) itself
    # raises URI::InvalidURIError — a StandardError — which the job's own
    # `rescue StandardError` would silently swallow before any HTTP call is
    # ever attempted. Deleting the `return if url.blank?` guard entirely
    # therefore produces the exact same observable result these two tests
    # used to check (no request, nothing raised out of #perform_now) — a
    # test that can't tell "no monitor configured, correctly skipped" apart
    # from "tried, failed at URI.parse, and got rescued like any other
    # failure." Asserting nothing was *logged* is what only the guard can
    # produce: the guarded path returns before the begin/rescue is ever
    # reached, so it never logs; the unguarded path's rescue always does.
    test "a blank URL performs no HTTP call and logs nothing" do
      ENV["HEARTBEAT_URL"] = ""

      logged_errors = capture_logged_errors { HeartbeatJob.perform_now }

      assert_not_requested :get, /.*/
      assert_empty logged_errors
    end

    test "an absent URL performs no HTTP call and logs nothing" do
      ENV.delete("HEARTBEAT_URL")

      logged_errors = capture_logged_errors { HeartbeatJob.perform_now }

      assert_not_requested :get, /.*/
      assert_empty logged_errors
    end

    test "a failing ping does not raise, but does log the failure" do
      ENV["HEARTBEAT_URL"] = "https://heartbeat.example/ping/abc123"
      stub_request(:get, "https://heartbeat.example/ping/abc123").to_raise(SocketError)

      logged_errors = nil
      assert_nothing_raised { logged_errors = capture_logged_errors { HeartbeatJob.perform_now } }

      assert_equal 1, logged_errors.size
      assert_match(/SocketError/, logged_errors.first)
    end

    test "runs with no tenant, like any TenantFree job" do
      assert_includes HeartbeatJob.ancestors, TenantFree
    end

    # Net::HTTP's own defaults are 60s open + 60s read — this pins the fix
    # (explicit open_timeout/read_timeout on the Net::HTTP.start call) by
    # capturing what actually reaches it, not just that HeartbeatJob::HTTP_TIMEOUT
    # exists as a constant somewhere unused.
    test "configures a short, explicit HTTP timeout" do
      ENV["HEARTBEAT_URL"] = "https://heartbeat.example/ping/abc123"
      stub_request(:get, "https://heartbeat.example/ping/abc123").to_return(status: 200)

      options = capture_net_http_start_options { HeartbeatJob.perform_now }

      assert_operator options[:open_timeout], :<=, 10
      assert_operator options[:read_timeout], :<=, 10
    end

    private
      # Minitest 6 (installed here) split Minitest::Mock / Object#stub out
      # into a separate gem this app doesn't depend on — see the same
      # pattern in test/jobs/ops/queue_health_job_test.rb. Swaps in a
      # temporary #error singleton method on the shared Rails.logger so a
      # test can tell "the rescue block ran and logged" apart from "nothing
      # happened," then restores the original.
      def capture_logged_errors
        original = Rails.logger.method(:error)
        errors = []
        Rails.logger.define_singleton_method(:error) { |message = nil, &block| errors << (message || block&.call) }

        yield

        errors
      ensure
        Rails.logger.define_singleton_method(:error, original)
      end

      # Net::HTTP.start(address, *arg, &block) has no declared keyword
      # parameters, so the options HeartbeatJob passes (use_ssl:,
      # open_timeout:, read_timeout:) arrive as a trailing positional Hash,
      # not real kwargs — this spy captures that Hash off the real argument
      # list rather than assuming a calling convention.
      def capture_net_http_start_options
        original = Net::HTTP.method(:start)
        captured = nil
        Net::HTTP.define_singleton_method(:start) do |*args, &block|
          captured = args.last.is_a?(Hash) ? args.last : {}
          original.call(*args, &block)
        end

        yield

        captured
      ensure
        Net::HTTP.define_singleton_method(:start, original)
      end
  end
end
