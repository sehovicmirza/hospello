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

    test "a blank URL performs no HTTP call and does not raise" do
      ENV["HEARTBEAT_URL"] = ""

      assert_nothing_raised { HeartbeatJob.perform_now }

      assert_not_requested :get, /.*/
    end

    test "an absent URL performs no HTTP call and does not raise" do
      ENV.delete("HEARTBEAT_URL")

      assert_nothing_raised { HeartbeatJob.perform_now }

      assert_not_requested :get, /.*/
    end

    test "a failing ping does not raise" do
      ENV["HEARTBEAT_URL"] = "https://heartbeat.example/ping/abc123"
      stub_request(:get, "https://heartbeat.example/ping/abc123").to_raise(SocketError)

      assert_nothing_raised { HeartbeatJob.perform_now }
    end

    test "runs with no tenant, like any TenantFree job" do
      assert_includes HeartbeatJob.ancestors, TenantFree
    end
  end
end
