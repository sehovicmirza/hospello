require "test_helper"

module Whatsapp
  # Deliberately thin: this job's real body belongs to Slice 6 Task 3's
  # Whatsapp::InboundRouter. What Task 2 has to prove is narrower — that the
  # class Webhooks::WhatsappController enqueues actually exists, sits on the
  # right queue, and can be performed with no ambient tenant without raising
  # — see the job's own class comment for why each of those is load-bearing
  # today, not merely tidy.
  class ProcessInboundJobTest < ActiveJob::TestCase
    test "runs on the critical queue, never behind the AI queue" do
      assert_equal "critical", ProcessInboundJob.new.queue_name
    end

    test "runs with no tenant, like any TenantFree job" do
      assert_includes ProcessInboundJob.ancestors, TenantFree
    end

    test "performing with a real webhook_event id does not raise" do
      event = WebhookEvent.create!(provider: :meta_cloud, external_id: "wamid.JOBTEST1", payload: { "a" => 1 })

      perform_enqueued_jobs { ProcessInboundJob.perform_later(event.id) }
    end
  end
end
