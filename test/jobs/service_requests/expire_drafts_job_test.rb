require "test_helper"

module ServiceRequests
  # A guest who starts "two extra towels…" and then goes to dinner must come
  # back to a clean slate. Two things go wrong without this job: a stale
  # summary card the guest no longer wants can still be confirmed, and the
  # abandoned draft holds the one-live-draft slot so their next request cannot
  # even start.
  class ExpireDraftsJobTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      @conversation = with_tenant(@hotel) { conversations(:stari_conversation) }
    end

    test "a draft past its expiry is closed" do
      stale = draft(expires_at: 1.minute.ago)

      ExpireDraftsJob.perform_now

      assert with_tenant(@hotel) { stale.reload.status_expired? }
    end

    test "a draft still within its window is left alone" do
      fresh = draft(expires_at: 10.minutes.from_now)

      ExpireDraftsJob.perform_now

      assert with_tenant(@hotel) { fresh.reload.status_gathering? }
    end

    test "a settled draft is not touched" do
      confirmed = draft(expires_at: 1.hour.ago, status: :confirmed)

      ExpireDraftsJob.perform_now

      assert with_tenant(@hotel) { confirmed.reload.status_confirmed? }
    end

    # The whole point. An expired draft is not confirmable, so the towels
    # never arrive at 23:00.
    test "an expired draft can no longer become a request" do
      stale = draft(expires_at: 1.minute.ago, status: :awaiting_confirmation)

      ExpireDraftsJob.perform_now

      with_tenant(@hotel) do
        assert_raises(ServiceRequestDraft::NotConfirmable) { stale.reload.confirm! }
        assert_equal 0, ServiceRequest.count
      end
    end

    test "expiring frees the slot so the guest's next request can start" do
      draft(expires_at: 1.minute.ago)

      ExpireDraftsJob.perform_now

      assert with_tenant(@hotel) {
        @conversation.service_request_drafts.create!(request_category: request_categories(:stari_towels)).persisted?
      }
    end

    # It sweeps every hotel, and the sweep is the reason: a hotel with no
    # traffic still has to have its stale drafts cleaned up, and a job scoped
    # to one hotel would never run for them.
    test "every hotel is swept, not just whichever happened to be current" do
      mine = draft(expires_at: 1.minute.ago)
      theirs = with_tenant(hotels(:vrelo)) do
        conversations(:vrelo_conversation).service_request_drafts.create!(
          request_category: request_categories(:vrelo_wakeup), expires_at: 1.minute.ago
        )
      end

      ExpireDraftsJob.perform_now

      assert with_tenant(@hotel) { mine.reload.status_expired? }
      assert with_tenant(hotels(:vrelo)) { theirs.reload.status_expired? }
    end

    # A draft whose category was deactivated after the guest started it is
    # still an abandoned draft holding a slot, and still has to close.
    test "a draft whose category was deactivated meanwhile still expires" do
      stale = draft(expires_at: 1.minute.ago)
      with_tenant(@hotel) { request_categories(:stari_towels).update!(active: false) }

      ExpireDraftsJob.perform_now

      assert with_tenant(@hotel) { stale.reload.status_expired? }
    end

    private

    def draft(expires_at:, status: :gathering)
      with_tenant(@hotel) do
        @conversation.service_request_drafts.create!(
          request_category: request_categories(:stari_towels), status: status, expires_at: expires_at
        )
      end
    end
  end
end
