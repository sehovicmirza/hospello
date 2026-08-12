require "test_helper"

# The registry, from a hotel's side: record what Meta approved, so anyone at
# the hotel can answer "is our welcome message usable yet?" without logging
# into Meta's dashboard.
#
# Nothing here submits anything to Meta or sends anything to a guest, and the
# tests are written to keep that true — this slice ships no bulk-send UI on
# purpose, because an un-opted-in template send risks the hotel's number.
#
# stari_admin and stari_staff both read the workspace in Bosnian (see
# test/fixtures/users.yml), so the strings asserted below are the literal
# Bosnian from config/locales/staff.bs.yml, pasted rather than looked up
# through I18n.t (engineering rule 2).
class Staff::WhatsappTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    @admin = users(:stari_admin)
    @staff = users(:stari_staff)
  end

  # --- Reading ----------------------------------------------------------------

  test "the channel screen lists this hotel's templates with what Meta said about each" do
    sign_in @staff

    get edit_staff_whatsapp_channel_path

    assert_response :success
    assert_select "##{dom_id(whatsapp_templates(:stari_welcome_bs))}", text: /Meta odobrila/
    assert_select "##{dom_id(whatsapp_templates(:stari_offer_bs))}", text: /Meta odbila/
  end

  # Meta's own words, verbatim: a hotel arguing with a rejection needs the
  # reason it was actually given, not a paraphrase of it.
  test "a rejection shows the reason Meta itself gave" do
    sign_in @staff

    get edit_staff_whatsapp_channel_path

    assert_select "##{dom_id(whatsapp_templates(:stari_offer_bs))}",
                  text: /Template content violates promotional messaging policy/
  end

  test "another hotel's templates are nowhere on the page" do
    sign_in @admin

    get edit_staff_whatsapp_channel_path

    assert_select "##{dom_id(with_tenant(hotels(:vrelo)) { whatsapp_templates(:vrelo_welcome_de) })}", count: 0
  end

  test "a hotel with nothing recorded is told so rather than shown an empty box" do
    sign_in users(:vrelo_admin)
    with_tenant(hotels(:vrelo)) { WhatsappTemplate.destroy_all }

    get edit_staff_whatsapp_channel_path

    assert_select "#whatsapp-templates-empty"
  end

  # --- Recording ---------------------------------------------------------------

  test "a hotel admin can record a template Meta approved" do
    sign_in @admin

    post staff_whatsapp_templates_path, params: { whatsapp_template: {
      name: "checkout_reminder", locale: "bs", category: "utility", status: "approved",
      body: "Odjava je u {{1}}."
    } }

    assert_redirected_to edit_staff_whatsapp_channel_path
    template = with_tenant(@hotel) { WhatsappTemplate.find_by!(name: "checkout_reminder") }
    assert_equal @hotel, template.hotel
    assert template.usable?
  end

  test "a name Meta would refuse comes back as a readable error, not a saved row" do
    sign_in @admin

    post staff_whatsapp_templates_path, params: { whatsapp_template: { name: "Checkout Reminder", locale: "bs" } }

    assert_response :unprocessable_content
    assert_select "#whatsapp-templates", text: /lowercase/
    assert_equal 0, with_tenant(@hotel) { WhatsappTemplate.where(locale: "bs", name: "Checkout Reminder").count }
  end

  # The error has to come back on the screen the hotel typed into, with the
  # rest of the channel still on it — not on a page of its own that has lost
  # the context.
  test "an invalid submission re-renders the channel screen, not a bare form" do
    sign_in @admin

    post staff_whatsapp_templates_path, params: { whatsapp_template: { name: "Bad Name", locale: "bs" } }

    assert_select "#whatsapp-channel-state"
    assert_select "##{dom_id(whatsapp_templates(:stari_welcome_bs))}"
  end

  test "editing a template updates it and returns to the channel screen" do
    sign_in @admin
    template = with_tenant(@hotel) { whatsapp_templates(:stari_offer_bs) }

    patch staff_whatsapp_template_path(template), params: { whatsapp_template: { status: "approved" } }

    assert_redirected_to edit_staff_whatsapp_channel_path
    assert with_tenant(@hotel) { template.reload.usable? }
  end

  test "removing a template takes it off the list" do
    sign_in @admin
    template = with_tenant(@hotel) { whatsapp_templates(:stari_offer_bs) }

    assert_difference -> { with_tenant(@hotel) { WhatsappTemplate.count } }, -1 do
      delete staff_whatsapp_template_path(template)
    end

    assert_redirected_to edit_staff_whatsapp_channel_path
  end

  # --- Who may do what ----------------------------------------------------------

  # A receptionist reads this to answer "why did that message not go out?" —
  # a template still pending at Meta is the likeliest answer, and that is a
  # shift question. Recording what Meta decided is bookkeeping.
  test "a receptionist may read the list but not add to it" do
    sign_in @staff

    post staff_whatsapp_templates_path, params: { whatsapp_template: { name: "sneaky", locale: "bs" } }

    assert_response :forbidden
    assert_equal 0, with_tenant(@hotel) { WhatsappTemplate.where(name: "sneaky").count }
  end

  test "a receptionist may not remove one either" do
    sign_in @staff

    delete staff_whatsapp_template_path(with_tenant(@hotel) { whatsapp_templates(:stari_welcome_bs) })

    assert_response :forbidden
    assert with_tenant(@hotel) { WhatsappTemplate.exists?(name: "welcome") }
  end

  # --- Tenancy ------------------------------------------------------------------

  # The boundary every staff controller keeps the same way: the id is looked
  # up through Current.hotel's own association, so a foreign one 404s before
  # authorize is even reached.
  test "another hotel's template id cannot be edited, deleted or even found" do
    sign_in @admin
    other = with_tenant(hotels(:vrelo)) { whatsapp_templates(:vrelo_welcome_de) }

    # 404, not 403: the lookup goes through Current.hotel's own association,
    # so a foreign id is not "refused" — from inside this hotel it does not
    # exist, which is also the answer that leaks least.
    patch staff_whatsapp_template_path(other), params: { whatsapp_template: { status: "approved" } }
    assert_response :not_found

    delete staff_whatsapp_template_path(other)
    assert_response :not_found

    assert with_tenant(hotels(:vrelo)) { other.reload.status_pending? }
  end

  # What actually protects this is acts_as_tenant, not the permitted-parameter
  # list — measured: adding :hotel_id to `permit` leaves this test **green**,
  # because the record is built through Current.hotel's association and
  # acts_as_tenant writes the current tenant's id over whatever was assigned.
  # Exactly the finding tools_test.rb records about log_unanswered_question,
  # and worth knowing before anyone concludes the strong-params list is the
  # guard here. This is a regression test against a future controller that
  # builds the record some other way, not a check on today's `permit`.
  test "a hotel_id in the body cannot file a template under another hotel" do
    sign_in @admin

    post staff_whatsapp_templates_path, params: { whatsapp_template: {
      name: "smuggled", locale: "bs", hotel_id: hotels(:vrelo).id
    } }

    assert_equal 0, with_tenant(hotels(:vrelo)) { WhatsappTemplate.where(name: "smuggled").count }
    assert_equal 1, with_tenant(@hotel) { WhatsappTemplate.where(name: "smuggled").count }
  end
end
