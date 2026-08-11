require "test_helper"

# The screen that made setting up a WhatsApp number a hotel-admin task rather
# than an engineering one. Before it, a `whatsapp_channels` row could only be
# created by hand on the production box — the "hidden manual step" this
# project's own rules forbid.
#
# stari_admin and stari_staff both read the workspace in Bosnian (see
# test/fixtures/users.yml), so every string asserted below is the literal
# Bosnian from config/locales/staff.bs.yml, pasted rather than looked up
# through I18n.t — deriving the expected value from the file the view reads
# would pass however empty that key became (engineering rule 2).
class Staff::WhatsappChannelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    @admin = users(:stari_admin)
    @staff = users(:stari_staff)
  end

  test "a hotel admin sees their own number and its current state" do
    sign_in @admin

    get edit_staff_whatsapp_channel_path

    assert_response :success
    assert_select "input[name='whatsapp_channel[phone_number_e164]'][value=?]", "+38761100100"
    assert_select "#whatsapp-channel-state", text: /Aktivno/
  end

  test "a hotel with no channel yet still gets the form, not an error" do
    sign_in users(:vrelo_admin)
    with_tenant(hotels(:vrelo)) { whatsapp_channels(:vrelo_whatsapp).destroy! }

    get edit_staff_whatsapp_channel_path

    assert_response :success
    assert_select "input[name='whatsapp_channel[phone_number_id]']"
  end

  # The gap this screen closes. A hotel admin creating the row is the whole
  # point; asserting it lands on the *right* hotel is the part that matters.
  test "saving for the first time creates the hotel's channel" do
    sign_in users(:vrelo_admin)
    with_tenant(hotels(:vrelo)) { whatsapp_channels(:vrelo_whatsapp).destroy! }

    patch staff_whatsapp_channel_path, params: { whatsapp_channel: {
      phone_number_e164: "+38761555777", phone_number_id: "NEW_PHONE_NUMBER_ID", status: "active"
    } }

    assert_redirected_to edit_staff_whatsapp_channel_path
    channel = with_tenant(hotels(:vrelo)) { WhatsappChannel.sole }
    assert_equal hotels(:vrelo), channel.hotel
    assert_equal "+38761555777", channel.phone_number_e164
    assert channel.active?
  end

  test "an existing channel is updated rather than duplicated" do
    sign_in @admin

    patch staff_whatsapp_channel_path, params: { whatsapp_channel: { status: "disabled" } }

    with_tenant(@hotel) do
      assert_equal 1, WhatsappChannel.count
      assert whatsapp_channels(:stari_grad_whatsapp).reload.disabled?
    end
  end

  # phone_number_id is globally unique because it is what routes an inbound
  # webhook to a hotel — so one hotel typing another's must be refused, not
  # merely unusual. Refused at both layers; this is the one a person sees.
  test "a phone_number_id another hotel already owns is refused with a readable error" do
    sign_in @admin

    patch staff_whatsapp_channel_path, params: { whatsapp_channel: {
      phone_number_e164: "+38761100100",
      phone_number_id: with_tenant(hotels(:vrelo)) { whatsapp_channels(:vrelo_whatsapp).phone_number_id }
    } }

    assert_response :unprocessable_content
    assert_equal "fixture-phone-number-id-stari",
                 with_tenant(@hotel) { whatsapp_channels(:stari_grad_whatsapp).reload.phone_number_id }
  end

  test "a phone number that is not a real number is refused" do
    sign_in @admin

    patch staff_whatsapp_channel_path, params: { whatsapp_channel: { phone_number_e164: "banana" } }

    assert_response :unprocessable_content
    assert_equal "+38761100100", with_tenant(@hotel) { whatsapp_channels(:stari_grad_whatsapp).reload.phone_number_e164 }
  end

  # Written by what actually happens on the channel — Whatsapp::InboundRouter
  # stamps last_inbound_at on every real delivery. A form that could set them
  # would let a hotel tell itself a number is working when nothing has ever
  # arrived on it.
  test "the fields that record what really happened cannot be typed in" do
    sign_in @admin
    before = with_tenant(@hotel) { whatsapp_channels(:stari_grad_whatsapp).last_inbound_at }

    patch staff_whatsapp_channel_path, params: { whatsapp_channel: {
      last_inbound_at: 1.minute.ago, verified_at: 1.minute.ago, last_error: "invented"
    } }

    with_tenant(@hotel) do
      channel = whatsapp_channels(:stari_grad_whatsapp).reload
      assert_equal before.to_i, channel.last_inbound_at.to_i
      assert_nil channel.last_error
    end
  end

  # --- Who may do what --------------------------------------------------------

  # A receptionist has to be able to answer "I messaged you on WhatsApp and
  # nobody replied" at 23:00 — that is a shift question. Changing the number
  # is not: it is the hotel's own published asset.
  test "a receptionist may read the settings" do
    sign_in @staff

    get edit_staff_whatsapp_channel_path

    assert_response :success
  end

  test "a receptionist may not change them" do
    sign_in @staff

    patch staff_whatsapp_channel_path, params: { whatsapp_channel: { status: "disabled" } }

    assert_response :forbidden
    assert with_tenant(@hotel) { whatsapp_channels(:stari_grad_whatsapp).reload.active? }
  end

  test "a deactivated staff member cannot reach the screen at all" do
    @staff.update!(active: false)
    sign_in @staff

    get edit_staff_whatsapp_channel_path

    assert_response :forbidden
  end

  # There is no id anywhere in this route, which is what makes reaching
  # another hotel's channel structurally impossible rather than merely
  # checked. Asserted anyway, because a future task adding an id would want
  # this to go red rather than quietly widen the surface.
  test "a smuggled id in the body cannot redirect the write to another hotel" do
    sign_in @admin
    other = with_tenant(hotels(:vrelo)) { whatsapp_channels(:vrelo_whatsapp) }

    patch staff_whatsapp_channel_path, params: {
      id: other.id, whatsapp_channel: { id: other.id, hotel_id: hotels(:vrelo).id, status: "disabled" }
    }

    assert with_tenant(hotels(:vrelo)) { other.reload.pending? }, "hotel B's channel must be untouched"
    assert with_tenant(@hotel) { whatsapp_channels(:stari_grad_whatsapp).reload.disabled? },
      "and the write must have landed on the signed-in admin's own hotel"
  end

  # The nav is how anyone finds this screen; a page nobody can reach is a
  # console step with extra steps.
  test "the workspace links to it" do
    sign_in @admin

    get staff_root_path

    assert_response :success
    assert_select "a[href=?]", edit_staff_whatsapp_channel_path, text: "WhatsApp"
  end
end
