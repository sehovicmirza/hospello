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

  # --- The request-summary overlay ------------------------------------------
  #
  # readable_in is the model half of the overlay rule the request-summary
  # translation job (Ai::TranslateServiceRequestSummaryJob) and the digit
  # guard sit behind: a receptionist reads a translation, with the guest's
  # own words one tap away, and the original whenever there is nothing safe
  # to show instead. Full end-to-end coverage, including the digit guard
  # itself, lives in test/jobs/ai/translate_service_request_summary_job_test.rb
  # — these are the model's own contract in isolation.

  test "readable_in shows the original when nothing has been translated yet" do
    # ServiceRequestDraft#build_request is what actually keeps summary and
    # details_original equal at creation (asserted directly in
    # service_request_draft_test.rb); this constructs that same starting
    # state explicitly, because ServiceRequest.create! here does not.
    original = "Dodatni peškiri — količina: 3"
    request = create_request(quantity: "3", details_original: original, original_locale: "bs")
    request.update!(summary: original)

    text, source = request.readable_in(@hotel.staff_locale)

    assert_equal original, text
    assert_equal :original, source
  end

  test "readable_in shows the original when there was never one to translate (legacy rows)" do
    request = create_request(quantity: "4") # details_original blank, as every request created before this task's own

    text, source = request.readable_in(@hotel.staff_locale)

    assert_equal request.summary, text
    assert_equal :original, source
  end

  test "readable_in shows the translation once the job has actually overwritten summary" do
    request = create_request(quantity: "5", details_original: "Dodatni peškiri — količina: 5", original_locale: "bs")
    request.update!(summary: "Extra towels — quantity: 5") # what the translation job itself does on success

    text, source = request.readable_in(@hotel.staff_locale)

    assert_equal "Extra towels — quantity: 5", text
    assert_equal :translated, source
  end

  test "readable_in falls back to the original for a reader in a different locale than the translation" do
    request = create_request(quantity: "6", details_original: "Dodatni peškiri — količina: 6", original_locale: "bs")
    request.update!(summary: "Extra towels — quantity: 6") # translated into the hotel's own staff_locale (bs)

    text, source = request.readable_in("de")

    assert_equal request.details_original, text
    assert_equal :original, source
  end

  # The immutability guarantee, enforced rather than merely observed — same
  # shape as Message#body_is_immutable_after_creation. Broken and restored
  # to prove it actually fires: temporarily removing this validation left
  # this exact test red with "expected request.valid? to be false".
  test "details_original cannot be changed after creation" do
    request = create_request(quantity: "7", details_original: "Dodatni peškiri — količina: 7", original_locale: "bs")

    request.details_original = "something else entirely"

    assert_not request.valid?
    assert_includes request.errors[:details_original], "cannot be changed after creation"
  end

  # --- retention: taking the guest out and leaving the work behind -----------

  test "anonymizing keeps the request and drops every part of it that is about a person" do
    request = create_request(quantity: "7", details_original: "Dodatni peškiri za g. Halilovića, soba 302",
      original_locale: "bs")

    ServiceRequest.where(id: request.id).anonymize_all!

    request.reload
    assert_nil request.details_original
    assert_nil request.original_locale
    assert_nil request.guest_session_id
    assert_nil request.conversation_id
    assert_nil request.room_id
    assert_empty request.details
    assert_equal request_categories(:stari_towels).name, request.summary
    assert request.anonymized?
  end

  test "anonymizing leaves the hotel's own record of the work intact" do
    request = create_request(quantity: "7", details_original: "Dodatni peškiri", original_locale: "bs")
    request.transition!(to: :accepted, by: users(:stari_staff))
    created_at, acknowledged_at = request.created_at, request.reload.acknowledged_at

    ServiceRequest.where(id: request.id).anonymize_all!

    request.reload
    assert_equal "accepted", request.status
    assert_equal request_categories(:stari_towels).id, request.request_category_id
    assert_equal request_categories(:stari_towels).department_id, request.department_id
    assert_equal users(:stari_staff).id, request.acknowledged_by_id
    assert_equal acknowledged_at.to_i, request.acknowledged_at.to_i
    assert_equal created_at.to_i, request.created_at.to_i
  end

  # Idempotence matters here more than it usually does: the nightly purge
  # re-reads the same 365-day window every night, and a second pass that
  # re-derived `summary` from a category, or moved `anonymized_at` forward,
  # would quietly rewrite rows forever and lie about when the data went.
  test "anonymizing a row a second time does nothing at all" do
    request = create_request(quantity: "9", details_original: "Dodatni peškiri", original_locale: "bs")
    ServiceRequest.where(id: request.id).anonymize_all!
    first_pass = request.reload.anonymized_at

    travel 1.day do
      assert_equal 0, ServiceRequest.where(id: request.id).anonymize_all!
    end

    assert_equal first_pass.to_i, request.reload.anonymized_at.to_i
  end

  # The immutability validation above and this write are not in conflict:
  # that guard exists to stop a *translation* overwriting an original, and
  # retention is the one thing allowed past it — through update_all, which
  # is visibly a different kind of write. The guard has to still be there
  # afterwards, which is what this pins.
  test "clearing the original for retention does not open the ordinary way in" do
    request = create_request(quantity: "11", details_original: "Dodatni peškiri", original_locale: "bs")

    assert_raises(ActiveRecord::RecordInvalid) do
      request.update!(details_original: "something else entirely")
    end
  end

  private

  def create_request(quantity: "2", details_original: nil, original_locale: nil)
    details = { "quantity" => quantity }
    conversation = conversations(:stari_conversation)
    category = request_categories(:stari_towels)

    ServiceRequest.create!(
      hotel: @hotel, conversation: conversation, guest_session: conversation.guest_session,
      room: conversation.guest_session.room, request_category: category, department: category.department,
      summary: "Extra towels — quantity: #{quantity}", details: details, channel: :web,
      details_original: details_original, original_locale: original_locale,
      dedupe_key: ServiceRequest.dedupe_key_for(conversation: conversation, category: category, details: details)
    )
  end
end
