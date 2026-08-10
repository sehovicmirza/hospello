require "test_helper"

# The class that keeps Slice 4's central promise: the assistant may gather and
# propose, but only a human may confirm. Every guarantee asserted here is
# either enforced by Postgres or refuses loudly — none of them rely on a
# caller remembering to check.
class ServiceRequestDraftTest < ActiveSupport::TestCase
  setup do
    @hotel = hotels(:stari_grad)
    ActsAsTenant.current_tenant = @hotel
    @conversation = conversations(:stari_conversation)
    @category = request_categories(:stari_towels) # detail_fields: quantity, description
  end

  # --- One live draft per conversation ---------------------------------------

  # A guest cannot end up confirming one request while reading the summary of
  # another. Enforced by the partial unique index, so a second concurrent
  # writer loses at the database rather than at a check it might not have run.
  test "a second live draft for the same conversation is impossible" do
    draft(status: :gathering)

    assert_raises(ActiveRecord::RecordNotUnique) do
      ServiceRequestDraft.new(
        conversation: @conversation, request_category: @category, status: :gathering,
        expires_at: 30.minutes.from_now
      ).save!(validate: false)
    end
  end

  test "a settled draft leaves room for a new one" do
    first = draft(status: :gathering)
    first.update!(status: :discarded)

    assert draft(status: :gathering).persisted?
  end

  test "live_for finds the conversation's open draft and ignores settled ones" do
    settled = draft(status: :gathering)
    settled.update!(status: :expired)
    live = draft(status: :awaiting_confirmation)

    assert_equal live, ServiceRequestDraft.live_for(@conversation)
  end

  # --- Knowing what is still missing -------------------------------------------

  test "missing_fields lists what the category asks for and this draft lacks, in order" do
    partial = draft(details: { "quantity" => "2" })

    assert_equal [ "description" ], partial.missing_fields
    assert_not partial.ready?
  end

  test "a draft with every field is ready" do
    complete = draft(details: { "quantity" => "2", "description" => "bath towels" })

    assert_empty complete.missing_fields
    assert complete.ready?
  end

  test "a draft with no category yet is never ready" do
    assert_not draft(category: nil).ready?
  end

  # --- Confirming ---------------------------------------------------------------

  test "confirm! creates the request from the draft" do
    ready = draft(status: :awaiting_confirmation, details: { "quantity" => "2", "description" => "bath towels" })

    request = ready.confirm!

    assert request.persisted?
    assert_equal @category, request.request_category
    assert_equal @category.department, request.department, "denormalized so a later category edit cannot rewrite history"
    assert_equal({ "quantity" => "2", "description" => "bath towels" }, request.details)
    assert_equal "bs", request.original_locale
    assert request.status_new?, "a guest confirming their own request commits the hotel to nothing"
    assert_equal "ai", request.source
    assert ready.reload.status_confirmed?
  end

  test "confirm! refuses a draft that is still gathering" do
    gathering = draft(status: :gathering, details: { "quantity" => "2" })

    assert_raises(ServiceRequestDraft::NotConfirmable) { gathering.confirm! }
    assert_equal 0, ServiceRequest.count, "no summary was ever shown, so nobody agreed to anything"
  end

  # Calling twice is not hypothetical: a model can emit the same tool call
  # twice in one turn, and a guest on a slow phone taps Confirm twice.
  test "confirm! creates exactly one request even if called twice" do
    ready = draft(status: :awaiting_confirmation, details: { "quantity" => "2", "description" => "towels" })

    ready.confirm!

    assert_raises(ServiceRequestDraft::NotConfirmable) { ready.confirm! }
    assert_equal 1, ServiceRequest.count
  end

  # The same request arriving twice by two different routes — a retried job, a
  # second draft raised after the first was confirmed — collapses at the
  # database rather than at whichever caller thought to look.
  test "the database itself rejects a duplicate request" do
    details = { "quantity" => "2", "description" => "towels" }
    first = draft(status: :awaiting_confirmation, details: details).confirm!

    assert_raises(ActiveRecord::RecordNotUnique) do
      first.dup.tap { |copy| copy.id = nil }.save!(validate: false)
    end
  end

  # ...and from the guest's side that is a success, not a failure. They asked
  # for two towels at six and two towels at six are on the board; telling them
  # something went wrong would invite them to ask again, which is how one
  # request becomes two.
  test "confirming the same thing twice yields the one request, not an error" do
    details = { "quantity" => "2", "description" => "towels" }
    first = draft(status: :awaiting_confirmation, details: details).confirm!

    second = draft(status: :awaiting_confirmation, details: details)
    again = second.confirm!

    assert_equal first, again
    assert_equal 1, ServiceRequest.count
    assert second.reload.status_confirmed?, "the duplicate draft has to settle too, or it holds the slot forever"
  end

  test "a genuinely different request is not treated as a duplicate" do
    draft(status: :awaiting_confirmation, details: { "quantity" => "2", "description" => "towels" }).confirm!

    other = draft(status: :awaiting_confirmation, details: { "quantity" => "3", "description" => "towels" })

    assert other.confirm!.persisted?
    assert_equal 2, ServiceRequest.count
  end

  test "an expired draft never becomes a request" do
    stale = draft(status: :awaiting_confirmation, details: { "quantity" => "2", "description" => "towels" })
    stale.update!(expires_at: 1.minute.ago)

    assert_raises(ServiceRequestDraft::NotConfirmable) { stale.confirm! }
    assert_equal 0, ServiceRequest.count
  end

  # The injection test for this slice. A model persuaded to emit another
  # room's id must not be able to route a request there — the room is not an
  # argument, it comes from the guest's own session.
  test "the room comes from the guest session, not from the details hash" do
    other_room = rooms(:stari_302)
    ready = draft(
      status: :awaiting_confirmation,
      details: { "quantity" => "2", "description" => "towels", "room_id" => other_room.id, "room" => "102" }
    )

    request = ready.confirm!

    assert_equal @conversation.guest_session.room, request.room
    assert_not_equal other_room, request.room
  end

  test "the hotel comes from the conversation, not from anything supplied" do
    ready = draft(
      status: :awaiting_confirmation,
      details: { "quantity" => "2", "description" => "towels", "hotel_id" => hotels(:vrelo).id }
    )

    assert_equal @hotel, ready.confirm!.hotel
  end

  test "the summary reads as something a receptionist can act on" do
    ready = draft(status: :awaiting_confirmation, details: { "quantity" => "2", "description" => "bath towels" })

    summary = ready.confirm!.summary

    assert_includes summary, @category.name
    assert_includes summary, "2"
    assert_includes summary, "bath towels"
  end

  test "a requested time in the details reaches the request" do
    ready = draft(
      status: :awaiting_confirmation,
      details: { "quantity" => "2", "description" => "towels", "requested_for_at" => "2026-08-11T18:00:00+02:00" }
    )

    assert_equal Time.utc(2026, 8, 11, 16, 0), ready.confirm!.requested_for_at
  end

  # A time we could not parse must not silently become "now" — a receptionist
  # reading "requested for 14:32" when the guest said "tomorrow evening" is
  # worse than reading nothing.
  test "an unparseable time is dropped rather than guessed" do
    ready = draft(
      status: :awaiting_confirmation,
      details: { "quantity" => "2", "description" => "towels", "requested_for_at" => "sometime this evening-ish" }
    )

    assert_nil ready.confirm!.requested_for_at
  end

  test "a draft expires half an hour out by default" do
    assert_in_delta ServiceRequestDraft::LIFETIME.from_now, draft.expires_at, 5.seconds
  end

  test "a conversation from another hotel is refused" do
    other = with_tenant(hotels(:vrelo)) { conversations(:vrelo_conversation) }
    invalid = ServiceRequestDraft.new(conversation_id: other.id, request_category: @category)

    assert_not invalid.valid?
    assert_includes invalid.errors[:conversation], "must belong to the same hotel"
  end

  private

  def draft(status: :gathering, details: {}, category: :default)
    @conversation.service_request_drafts.create!(
      request_category: category == :default ? @category : category,
      status: status, details: details
    )
  end
end
