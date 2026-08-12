require "test_helper"

# The way in to an irreversible action. Three things have to hold, and each
# one has its own test below rather than being folded into a happy path:
# only a platform admin gets here at all, another hotel's guest cannot be
# reached through this hotel's URL, and the confirmation names what is
# actually about to go.
#
# **Two of the three are held by two independent layers each, and these tests
# cannot tell which one is working.** Measured, not reasoned about, and
# recorded here so nobody deletes one as redundant — the same finding, and
# the same note, Slices 4 and 6 already carry:
#
#   - "only a platform admin may erase" is enforced by
#     Platform::BaseController#require_platform_admin *and* by
#     GuestErasurePolicy. Widening either one alone leaves every test in this
#     file green; widening both turns the two hotel-admin tests red.
#   - "another hotel's guest cannot be reached" is enforced by looking the
#     session up through `@hotel.guest_sessions` *and* by acts_as_tenant's
#     own scope. Replacing the association with a bare `GuestSession.find`
#     leaves everything green, because the tenant block still narrows it;
#     only defeating both makes the two cross-hotel tests red.
class Platform::GuestErasuresControllerTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    @vrelo = hotels(:vrelo)
    @session = guest_sessions(:stari_guest)
  end

  # --- who may be here ------------------------------------------------------

  test "a hotel admin cannot reach the erasure screen for their own hotel" do
    sign_in users(:stari_admin)

    get platform_hotel_guest_erasures_path(@hotel)

    assert_response :forbidden
  end

  test "a receptionist cannot reach it either" do
    sign_in users(:stari_staff)

    get platform_hotel_guest_erasures_path(@hotel)

    assert_response :forbidden
  end

  test "a hotel admin cannot erase a guest by posting straight at it" do
    sign_in users(:stari_admin)

    assert_no_difference -> { with_tenant(@hotel) { GuestSession.count } } do
      post platform_hotel_guest_erasures_path(@hotel), params: { guest_session_id: @session.id }
    end
    assert_response :forbidden
  end

  test "signed out, the erasure screen is not reachable" do
    get platform_hotel_guest_erasures_path(@hotel)

    assert_redirected_to new_session_path
  end

  # A platform admin whose account has been deactivated keeps a valid session
  # cookie — deactivation is the only thing that takes cross-hotel access
  # away, so it has to take this away too.
  test "a deactivated platform admin cannot erase anything" do
    sign_in users(:platform)
    users(:platform).update!(active: false)

    post platform_hotel_guest_erasures_path(@hotel), params: { guest_session_id: @session.id }

    assert_response :forbidden
    assert with_tenant(@hotel) { GuestSession.exists?(@session.id) }
  end

  # --- one hotel's guests, never another's ----------------------------------

  test "another hotel's guest session cannot be reached through this hotel's URL" do
    sign_in users(:platform)

    get new_platform_hotel_guest_erasure_path(@hotel, guest_session_id: guest_sessions(:vrelo_guest).id)

    assert_response :not_found
  end

  test "another hotel's guest session cannot be erased through this hotel's URL" do
    sign_in users(:platform)
    victim = guest_sessions(:vrelo_guest)

    post platform_hotel_guest_erasures_path(@hotel), params: { guest_session_id: victim.id }

    assert_response :not_found
    assert with_tenant(@vrelo) { GuestSession.exists?(victim.id) }
  end

  test "the list shows only this hotel's guests" do
    sign_in users(:platform)

    get platform_hotel_guest_erasures_path(@hotel)

    assert_response :success
    assert_select "#guest-sessions", text: /Amira Fixture/
    assert_select "#guest-sessions", text: /Marko Fixture/, count: 0
  end

  test "the search finds a guest by room number" do
    sign_in users(:platform)

    get platform_hotel_guest_erasures_path(@hotel, q: "301")

    assert_response :success
    assert_select "#guest-sessions tbody tr", count: 1
    assert_select "#guest-sessions", text: /Amira Fixture/
  end

  test "a search matching nobody says so rather than showing everybody" do
    sign_in users(:platform)

    get platform_hotel_guest_erasures_path(@hotel, q: "nobody-by-that-name")

    assert_response :success
    assert_select "#guest-sessions", count: 0
    assert_select "#no-guest-sessions"
  end

  # --- the confirmation -----------------------------------------------------

  # Irreversible, so it names what it is about to destroy. "Are you sure?" is
  # a question nobody reads; "3 messages" is a number they do.
  test "the confirmation names the guest and counts what is about to go" do
    sign_in users(:platform)

    get new_platform_hotel_guest_erasure_path(@hotel, guest_session_id: @session.id)

    assert_response :success
    assert_select "#erasure-confirmation", text: /cannot be undone/
    assert_select "#erasure-confirmation", text: /1 conversation/
    assert_select "#erasure-confirmation", text: /1 message/
    assert_select "#erasure-confirmation", text: /301/, count: 1
  end

  test "the confirmation destroys nothing by itself" do
    sign_in users(:platform)

    assert_no_difference [ -> { with_tenant(@hotel) { GuestSession.count } },
                            -> { with_tenant(@hotel) { Message.count } } ] do
      get new_platform_hotel_guest_erasure_path(@hotel, guest_session_id: @session.id)
    end
  end

  # --- doing it -------------------------------------------------------------

  test "a platform admin erases the guest, and is told what went" do
    sign_in users(:platform)
    # Read before the erasure, deliberately: a fixture accessor queries the
    # database, so `messages(:stari_first_message)` afterwards raises
    # RecordNotFound — which would read as a test error rather than as the
    # deletion this test exists to assert.
    message_id = with_tenant(@hotel) { messages(:stari_first_message).id }

    post platform_hotel_guest_erasures_path(@hotel), params: { guest_session_id: @session.id }

    assert_redirected_to platform_hotel_guest_erasures_path(@hotel)
    assert_match(/cannot be undone/, flash[:notice])
    assert_not with_tenant(@hotel) { GuestSession.exists?(@session.id) }
    assert_not with_tenant(@hotel) { Message.exists?(message_id) }
  end

  test "erasing one guest leaves the rest of the hotel alone" do
    sign_in users(:platform)
    vrelo_message_id = with_tenant(@vrelo) { messages(:vrelo_first_message).id }

    post platform_hotel_guest_erasures_path(@hotel), params: { guest_session_id: @session.id }

    with_tenant(@hotel) do
      assert KbEntry.any?, "the hotel's own knowledge base is not guest data"
      assert Room.exists?(rooms(:stari_301).id), "the room itself is the hotel's, not the guest's"
    end
    with_tenant(@vrelo) { assert Message.exists?(vrelo_message_id) }
  end

  test "the erasure is audit-logged against the acting platform admin" do
    sign_in users(:platform)

    assert_difference -> { AuditLog.where(action: "guest_data.erase").count }, 1 do
      post platform_hotel_guest_erasures_path(@hotel), params: { guest_session_id: @session.id }
    end

    entry = AuditLog.where(action: "guest_data.erase").last
    assert_equal users(:platform).id, entry.actor_user_id
    assert_equal @hotel.id, entry.hotel_id
  end

  # --- findable at all ------------------------------------------------------

  # A screen nobody can find is a legal obligation actioned from a Rails
  # console on the production box.
  test "the hotel page links to it" do
    sign_in users(:platform)

    get platform_hotel_path(@hotel)

    assert_response :success
    assert_select "a[href=?]", platform_hotel_guest_erasures_path(@hotel)
  end
end
