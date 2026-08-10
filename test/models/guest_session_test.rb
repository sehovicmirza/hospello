require "test_helper"

class GuestSessionTest < ActiveSupport::TestCase
  test "authenticate_by_token finds an active session by its token digest" do
    hotel = hotels(:stari_grad)
    raw = SecureRandom.urlsafe_base64(32)

    session = with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Aisha", room: rooms(:stari_301), locale: "ar",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        token_digest: GuestSession.digest(raw)
      )
    end

    assert_equal session, GuestSession.authenticate_by_token(raw)
  end

  # The real call site (Guest::BaseController, on every guest request) has
  # no ambient tenant at all — the whole point of authenticate_by_token is
  # to discover *which* hotel from the cookie alone. This pins that the
  # lookup genuinely works with no tenant set, not just inside a with_tenant
  # block the way the test above (mirroring the brief's own example) does.
  test "authenticate_by_token works with no ambient tenant set — the real call site" do
    hotel = hotels(:stari_grad)
    raw = SecureRandom.urlsafe_base64(32)

    session = with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Karim", room: rooms(:stari_301), locale: "ar",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        token_digest: GuestSession.digest(raw)
      )
    end

    assert_nil ActsAsTenant.current_tenant, "sanity check: the with_tenant block above must have released the tenant"
    assert_equal session, GuestSession.authenticate_by_token(raw)
  end

  test "authenticate_by_token rejects an expired session" do
    hotel = hotels(:stari_grad)
    raw = SecureRandom.urlsafe_base64(32)

    with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Expired Guest", room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 1.hour.ago,
        token_digest: GuestSession.digest(raw)
      )
    end

    assert_nil GuestSession.authenticate_by_token(raw)
  end

  test "authenticate_by_token rejects a blocked session" do
    hotel = hotels(:stari_grad)
    raw = SecureRandom.urlsafe_base64(32)

    with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Blocked Guest", room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        token_digest: GuestSession.digest(raw), status: :blocked
      )
    end

    assert_nil GuestSession.authenticate_by_token(raw)
  end

  test "authenticate_by_token returns nil for garbage, and must not raise" do
    assert_nil GuestSession.authenticate_by_token("not-a-real-token-at-all")
    assert_nil GuestSession.authenticate_by_token("")
    assert_nil GuestSession.authenticate_by_token(nil)
  end

  test "the raw token is never stored — no column holds it" do
    assert_nil GuestSession.column_names.find { |name| name == "token" }
  end

  test "touch_activity! bumps last_seen_at and extends expiry by 7 days" do
    hotel = hotels(:stari_grad)

    session = with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Fresh Guest", room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 1.day.from_now,
        last_seen_at: 2.days.ago
      )
    end

    expected_now = nil
    travel_to 1.hour.from_now do
      expected_now = Time.current
      session.touch_activity!
    end

    assert_in_delta expected_now.to_i, session.last_seen_at.to_i, 5
    assert_in_delta (expected_now + 7.days).to_i, session.expires_at.to_i, 5
  end

  test "touch_activity! never extends expiry past 21 days from creation" do
    hotel = hotels(:stari_grad)

    session = with_tenant(hotel) do
      travel_to 20.days.ago do
        hotel.guest_sessions.create!(
          guest_name: "Long-Staying Guest", room: rooms(:stari_301), locale: "en",
          privacy_accepted_at: Time.current, expires_at: 7.days.from_now
        )
      end
    end

    session.touch_activity!

    assert session.expires_at <= session.created_at + 21.days
    assert_in_delta (session.created_at + 21.days).to_i, session.expires_at.to_i, 5
  end

  test "a new session is always unverified, even when the caller mass-assigns identity_status" do
    hotel = hotels(:stari_grad)

    session = with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Sneaky Guest", room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        identity_status: :staff_verified
      )
    end

    assert session.unverified?
    assert_not session.staff_verified?
  end

  # IMPORTANT 9 (review round 1): the original guard only ran `on: :create`,
  # so a plain `update` after the fact silently flipped identity_status —
  # the "always unverified" promise held only at construction, not on the
  # write path in general.
  test "identity_status cannot be flipped to staff_verified by an update after creation either" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      session = hotel.guest_sessions.create!(
        guest_name: "Guest", room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now
      )

      assert session.update(identity_status: :staff_verified)
      assert session.reload.unverified?
      assert_not session.staff_verified?
    end
  end

  test "guest_name is required" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      session = hotel.guest_sessions.new(
        room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now
      )

      assert_not session.valid?
      assert_includes session.errors[:guest_name], "can't be blank"
    end
  end

  test "privacy_accepted_at is required — no consent, no valid session" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      session = hotel.guest_sessions.new(
        guest_name: "No Consent Guest", room: rooms(:stari_301), locale: "en",
        expires_at: 7.days.from_now
      )

      assert_not session.valid?
      assert_includes session.errors[:privacy_accepted_at], "can't be blank"
    end
  end

  test "locale must be one of the four supported guest languages" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      session = hotel.guest_sessions.new(
        guest_name: "Guest", room: rooms(:stari_301), locale: "fr",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now
      )

      assert_not session.valid?
      assert_includes session.errors[:locale], "is not included in the list"
    end
  end

  test "room is optional — WhatsApp guests (Slice 6) start roomless" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      session = hotel.guest_sessions.new(
        guest_name: "Roomless Guest", locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now
      )

      assert session.valid?
    end
  end

  # Mirrors RequestCategory#department_must_belong_to_the_same_hotel: a
  # cross-tenant id assigned directly must not be accepted just because the
  # row exists somewhere.
  test "a room belonging to a different hotel is rejected" do
    vrelo_room_id = rooms(:vrelo_401).id

    with_tenant(hotels(:stari_grad)) do
      session = hotels(:stari_grad).guest_sessions.new(
        guest_name: "Cross-tenant Guest", room_id: vrelo_room_id, locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now
      )

      assert_not session.valid?
      assert_includes session.errors[:room], "must belong to the same hotel"
    end
  end
end
