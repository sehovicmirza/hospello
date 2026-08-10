require "test_helper"

# What a receptionist works from, and the record the guest's own status
# updates fire from. Everything asserted here is about the status being
# trustworthy: only #transition! may change it, every change is recorded with
# who made it, and a change that makes no sense raises rather than being
# quietly dropped onto a board somebody is reading.
class ServiceRequestTest < ActiveSupport::TestCase
  setup do
    @hotel = hotels(:stari_grad)
    ActsAsTenant.current_tenant = @hotel
    @staff = users(:stari_staff)
    @request = create_request
  end

  test "a new request commits the hotel to nothing" do
    assert @request.status_new?
    assert_nil @request.acknowledged_at
    assert_nil @request.completed_at
  end

  test "accepting records who did it and when" do
    @request.transition!(to: :accepted, by: @staff)

    assert @request.reload.status_accepted?
    assert_equal @staff, @request.acknowledged_by
    assert @request.acknowledged_at.present?
  end

  test "completing stamps the time" do
    @request.transition!(to: :accepted, by: @staff)
    @request.transition!(to: :completed, by: @staff)

    assert @request.reload.status_completed?
    assert @request.completed_at.present?
  end

  test "every transition writes an event naming who made it" do
    @request.transition!(to: :accepted, by: @staff, note: "Taking this one.")

    event = @request.request_events.last
    assert event.kind_status_change?
    assert_equal @staff, event.user
    assert_equal "new", event.from_status_name
    assert_equal "accepted", event.to_status_name
    assert_equal "Taking this one.", event.note
  end

  # A silently dropped status change would show a receptionist a board that
  # disagrees with reality — and, once Task 3 wires guest updates to these
  # events, would tell a guest something that never happened.
  test "a transition that makes no sense raises rather than being ignored" do
    # A new request cannot jump straight to in_progress: somebody has to have
    # picked it up first, and the board's counts depend on that being true.
    assert_raises(ServiceRequest::InvalidTransition) { @request.transition!(to: :in_progress, by: @staff) }
    assert @request.reload.status_new?
  end

  test "a finished request cannot be reopened" do
    @request.transition!(to: :accepted, by: @staff)
    @request.transition!(to: :completed, by: @staff)

    assert_raises(ServiceRequest::InvalidTransition) { @request.transition!(to: :in_progress, by: @staff) }
  end

  test "a request can be declined or cancelled straight from new" do
    assert create_request(quantity: "3").transition!(to: :declined, by: @staff).status_declined?
    assert create_request(quantity: "4").transition!(to: :cancelled, by: @staff).status_cancelled?
  end

  test "a failed transition leaves no event behind" do
    assert_no_difference -> { RequestEvent.count } do
      assert_raises(ServiceRequest::InvalidTransition) { @request.transition!(to: :in_progress, by: @staff) }
    end
  end

  # --- Overdue -------------------------------------------------------------

  test "a request older than the hotel's own threshold and still waiting is overdue" do
    @hotel.update!(overdue_after_minutes: 30)
    @request.update!(created_at: 31.minutes.ago)

    assert @request.overdue?
  end

  test "a request that has been dealt with is never overdue, however old" do
    @hotel.update!(overdue_after_minutes: 30)
    @request.update!(created_at: 5.hours.ago)
    @request.transition!(to: :accepted, by: @staff)
    @request.transition!(to: :completed, by: @staff)

    assert_not @request.reload.overdue?
  end

  test "each hotel sets its own idea of late" do
    @hotel.update!(overdue_after_minutes: 240)
    @request.update!(created_at: 31.minutes.ago)

    assert_not @request.overdue?
  end

  # --- The dedupe key ------------------------------------------------------

  test "the same request from the same conversation produces the same key" do
    arguments = {
      conversation: conversations(:stari_conversation), category: request_categories(:stari_towels),
      details: { "quantity" => "2" }, requested_for_at: Time.utc(2026, 8, 11, 18)
    }

    assert_equal ServiceRequest.dedupe_key_for(**arguments), ServiceRequest.dedupe_key_for(**arguments)
  end

  # A hash built in a different order is the same request. Without sorting,
  # two identical asks would produce different keys and the duplicate
  # guarantee would quietly stop working.
  test "detail order does not change the key" do
    base = { conversation: conversations(:stari_conversation), category: request_categories(:stari_towels) }

    assert_equal ServiceRequest.dedupe_key_for(**base, details: { "a" => "1", "b" => "2" }),
                 ServiceRequest.dedupe_key_for(**base, details: { "b" => "2", "a" => "1" })
  end

  test "two different guests asking the same thing are two requests" do
    base = { category: request_categories(:stari_towels), details: { "quantity" => "2" } }
    mine = ServiceRequest.dedupe_key_for(**base, conversation: conversations(:stari_conversation))
    theirs = with_tenant(hotels(:vrelo)) do
      ServiceRequest.dedupe_key_for(**base, conversation: conversations(:vrelo_conversation))
    end

    assert_not_equal mine, theirs
  end

  test "a different time is a different request" do
    base = {
      conversation: conversations(:stari_conversation), category: request_categories(:stari_towels),
      details: { "quantity" => "2" }
    }

    assert_not_equal ServiceRequest.dedupe_key_for(**base, requested_for_at: Time.utc(2026, 8, 11, 18)),
                     ServiceRequest.dedupe_key_for(**base, requested_for_at: Time.utc(2026, 8, 11, 19))
  end

  # --- Scopes --------------------------------------------------------------

  test "the board separates what still needs doing from what does not" do
    settled = create_request(quantity: "9")
    settled.transition!(to: :cancelled, by: @staff)

    assert_includes ServiceRequest.open_requests, @request
    assert_not_includes ServiceRequest.open_requests, settled
    assert_includes ServiceRequest.settled, settled
  end

  private

  def create_request(quantity: "2")
    details = { "quantity" => quantity }
    conversation = conversations(:stari_conversation)
    category = request_categories(:stari_towels)

    ServiceRequest.create!(
      hotel: @hotel, conversation: conversation, guest_session: conversation.guest_session,
      room: conversation.guest_session.room, request_category: category, department: category.department,
      summary: "Extra towels — quantity: #{quantity}", details: details, channel: :web,
      dedupe_key: ServiceRequest.dedupe_key_for(conversation: conversation, category: category, details: details)
    )
  end
end
