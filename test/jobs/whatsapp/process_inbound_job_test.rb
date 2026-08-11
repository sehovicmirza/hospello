require "test_helper"

module Whatsapp
  # The critical-queue entry point: one stored webhook_events row in, routed
  # guest activity out. What Whatsapp::InboundRouter actually *does* with a
  # payload is proved in test/services/whatsapp/inbound_router_test.rb; this
  # file is about the wiring around it — the queue it sits on, the fact that
  # it runs with no ambient tenant, what it does with an id that no longer
  # names anything, and that a message arriving here really does reach the
  # same reply pipeline a web message does.
  class ProcessInboundJobTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      @channel = with_tenant(@hotel) { whatsapp_channels(:stari_grad_whatsapp) }
      ActsAsTenant.current_tenant = nil
    end

    test "runs on the critical queue, never behind the AI queue" do
      assert_equal "critical", ProcessInboundJob.new.queue_name
    end

    test "runs with no tenant, like any TenantFree job" do
      assert_includes ProcessInboundJob.ancestors, TenantFree
    end

    # The whole point of the slice, asserted end to end from the queue: a
    # guest's WhatsApp message reaches the concierge through exactly the job
    # Conversation#post_guest_message! enqueues for a web guest. Nothing here
    # names WhatsApp — if it ever has to, the seam is in the wrong place.
    test "a routed guest message reaches the same reply pipeline the web uses" do
      event = stored_event

      assert_enqueued_with(job: Ai::GenerateReplyJob) do
        perform_enqueued_jobs(only: ProcessInboundJob) { ProcessInboundJob.perform_later(event.id) }
      end

      assert event.reload.processed?
      assert_equal "Dobar dan", with_tenant(@hotel) { Message.find_by!(external_id: "wamid.JOB1").body }
    end

    # The webhook controller deliberately enqueues a job for a *replay* too
    # (so a crash between insert and enqueue is recoverable), which makes two
    # performs of the same id the ordinary case rather than an exotic one.
    test "performing the same event twice produces exactly one message" do
      event = stored_event

      2.times { perform_enqueued_jobs(only: ProcessInboundJob) { ProcessInboundJob.perform_later(event.id) } }

      assert_equal 1, with_tenant(@hotel) { Message.where(external_id: "wamid.JOB1").count }
    end

    # A retention sweep is the only thing that removes one of these rows, and
    # a job for a delivery nobody keeps records of any more has nothing to do.
    # Raising would put it in the failed-jobs table for a human to read and
    # then discard.
    test "an id that no longer names anything is not an error" do
      assert_nothing_raised do
        perform_enqueued_jobs(only: ProcessInboundJob) { ProcessInboundJob.perform_later(-1) }
      end
    end

    private
      def stored_event
        WebhookEvent.create!(
          provider: :meta_cloud,
          external_id: "wamid.JOB1",
          payload: {
            "object" => "whatsapp_business_account",
            "entry" => [ {
              "id" => "WABA_ID",
              "changes" => [ {
                "field" => "messages",
                "value" => {
                  "messaging_product" => "whatsapp",
                  "metadata" => { "phone_number_id" => @channel.phone_number_id },
                  "contacts" => [ { "profile" => { "name" => "Amira W" }, "wa_id" => "38761234567" } ],
                  "messages" => [ {
                    "from" => "38761234567", "id" => "wamid.JOB1", "timestamp" => "1786449600",
                    "type" => "text", "text" => { "body" => "Dobar dan" }
                  } ]
                }
              } ]
            } ]
          }
        )
      end
  end
end
