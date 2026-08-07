require "test_helper"

module Ops
  # QueueHealthJob reads Solid Queue's own tables directly (not a web
  # request, not a health-check endpoint) and reports to Sentry when
  # something looks stuck. Sentry.capture_message is a real no-op when
  # Sentry isn't initialized (no SENTRY_DSN in test), so these tests swap in
  # a temporary singleton method to observe whether — and with what — it
  # would have been called, rather than asserting on Sentry's own internal
  # state. (Minitest 6 dropped Minitest::Mock/Object#stub into a separate
  # gem this app doesn't depend on, so this is a plain Ruby redefine/restore
  # instead.)
  class QueueHealthJobTest < ActiveSupport::TestCase
    test "reports nothing when there are no failures and the oldest ready job is fresh" do
      create_ready_execution(created_at: 1.minute.ago)

      calls = capture_sentry_calls { QueueHealthJob.perform_now }

      assert_empty calls
    end

    test "reports to Sentry when there is at least one failed execution" do
      create_failed_execution

      calls = capture_sentry_calls { QueueHealthJob.perform_now }

      assert_equal 1, calls.size
      assert_match(/1 failed/, calls.first)
    end

    test "reports to Sentry when the oldest ready job is older than 5 minutes" do
      create_ready_execution(created_at: 10.minutes.ago)

      calls = capture_sentry_calls { QueueHealthJob.perform_now }

      assert_equal 1, calls.size
      assert_match(/oldest ready job/, calls.first)
    end

    # Not "exactly 5 minutes ago": wall-clock time passes between building
    # that fixture and the job's own Time.current read inside perform, so an
    # exact-boundary timestamp is already older than 5 minutes by the time
    # it's checked — a flaky test, not a real edge case.
    test "does not report when the oldest ready job is comfortably under the 5-minute threshold" do
      create_ready_execution(created_at: 4.minutes.ago)

      calls = capture_sentry_calls { QueueHealthJob.perform_now }

      assert_empty calls
    end

    test "runs with no tenant, like any TenantFree job" do
      assert_includes QueueHealthJob.ancestors, TenantFree
    end

    private
      def create_job
        SolidQueue::Job.create!(queue_name: "low", class_name: "Ops::HeartbeatJob", arguments: "[]")
      end

      # SolidQueue::Job's after_create callback already inserts the
      # ReadyExecution row (see solid_queue's Job::Executable concern) — this
      # just backdates it to simulate a job that has been sitting unclaimed.
      def create_ready_execution(created_at:)
        job = create_job
        SolidQueue::ReadyExecution.find_by!(job: job).update_column(:created_at, created_at)
      end

      def create_failed_execution
        job = create_job
        SolidQueue::ReadyExecution.where(job: job).delete_all
        SolidQueue::FailedExecution.create!(
          job: job, error: { exception_class: "Boom", message: "boom", backtrace: [] }
        )
      end

      def capture_sentry_calls
        original = Sentry.method(:capture_message)
        calls = []
        Sentry.define_singleton_method(:capture_message) { |message, **_options| calls << message }

        yield

        calls
      ensure
        Sentry.define_singleton_method(:capture_message, original)
      end
  end
end
