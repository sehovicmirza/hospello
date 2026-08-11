require "test_helper"

# What each side actually reads. The pipeline is tested elsewhere; this is
# about the two rules that face a person:
#
#   * everyone reads in their own language, with the other's actual words one
#     tap away — and the original is in the DOM either way, so it is findable
#     with JavaScript off, by selection, or by a screen reader
#   * a message that could not be translated says so, rather than looking like
#     an ordinary message the reader is expected to understand
class TranslationRenderingTest < ActionDispatch::IntegrationTest
  GUEST_TOKEN = "stari-grad-fixture-guest-token".freeze

  setup do
    @hotel = hotels(:stari_grad)          # staff_locale: bs
    @staff = users(:stari_staff)
    @guest_session = with_tenant(@hotel) { guest_sessions(:stari_guest) }
    @conversation = with_tenant(@hotel) { Conversation.live_for(@guest_session) }
  end

  # --- The receptionist's side ------------------------------------------------

  test "a receptionist reads the guest's message in the hotel's language" do
    translated_message("Wann gibt es Frühstück?", role: :guest, from: "de", into: "bs", as: "Kada je doručak?")
    sign_in @staff

    get staff_conversation_path(@conversation)

    assert_response :success
    assert_select "*", text: /Kada je doručak\?/
  end

  test "the guest's own words are on the page too, ready to be revealed" do
    translated_message("Wann gibt es Frühstück?", role: :guest, from: "de", into: "bs", as: "Kada je doručak?")
    sign_in @staff

    get staff_conversation_path(@conversation)

    assert_select "[data-translation-toggle-target='original']", text: /Wann gibt es Frühstück\?/
    assert_select "[data-action='click->translation-toggle#toggle']"
  end

  # The failure case a receptionist has to be able to tell apart from an
  # ordinary message: they cannot read this one, and it is not their fault.
  test "a message that could not be translated says so" do
    with_tenant(@hotel) do
      @conversation.messages.create!(
        hotel: @hotel, sender_role: :guest, body: "Wann gibt es Frühstück?", body_locale: "de",
        translation_status: :failed
      )
    end
    sign_in @staff

    get staff_conversation_path(@conversation)

    assert_select "*", text: /Wann gibt es Frühstück\?/
    assert_select "*", text: /could not translate/i
  end

  test "a translation still in flight says that instead" do
    with_tenant(@hotel) do
      @conversation.messages.create!(
        hotel: @hotel, sender_role: :guest, body: "Wann gibt es Frühstück?", body_locale: "de",
        translation_status: :translating
      )
    end
    sign_in @staff

    get staff_conversation_path(@conversation)

    assert_select "*", text: /Translating/i
  end

  # Nothing to reveal, nothing to offer. A toggle on a message that was never
  # translated is a control that does nothing, which teaches a receptionist to
  # ignore the one that does.
  test "a message in the hotel's own language has no toggle at all" do
    with_tenant(@hotel) do
      @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "Kada je doručak?", body_locale: "bs")
    end
    sign_in @staff

    get staff_conversation_path(@conversation)

    assert_select "[data-action='click->translation-toggle#toggle']", count: 0
  end

  # --- The guest's side ---------------------------------------------------------

  test "a guest reads the hotel's reply in their own language" do
    speaking_german
    translated_message("Doručak je od 07:00.", role: :staff, from: "bs", into: "de", as: "Das Frühstück ist ab 07:00.")
    sign_in_guest GUEST_TOKEN

    get guest_chat_path

    assert_response :success
    assert_select "*", text: /Das Frühstück ist ab 07:00\./
    assert_select "[data-translation-toggle-target='original']", text: /Doručak je od 07:00\./
  end

  # A guest's own message is theirs. Showing it back to them translated would
  # be the software telling them what they said — and this is not
  # hypothetical: it is what the first version of this view did, because the
  # staff-facing translation of a guest's message happens to be in the same
  # language the guest's own interface renders in whenever the guest and the
  # hotel share a language on one side and not the other.
  #
  # Deliberately NOT using #speaking_german: the guest's interface has to be
  # in the language their message was translated *into* for this to be able to
  # fail at all.
  test "a guest's own message is never translated back to them" do
    translated_message("Wann gibt es Frühstück?", role: :guest, from: "de", into: "bs", as: "Kada je doručak?")
    sign_in_guest GUEST_TOKEN

    get guest_chat_path

    assert_select "*", text: /Wann gibt es Frühstück\?/
    assert_no_match "Kada je doručak?", response.body
  end

  # A translation aimed at somebody else is not a translation for you. Without
  # the locale check a German-speaking guest would be shown the Arabic version
  # of a reply that was translated for a different guest's conversation.
  test "a translation into a language the reader does not read is not shown" do
    speaking_german
    translated_message("Doručak je od 07:00.", role: :staff, from: "bs", into: "ar", as: "الإفطار من الساعة 07:00.")
    sign_in_guest GUEST_TOKEN

    get guest_chat_path

    assert_select "*", text: /Doručak je od 07:00\./
    assert_no_match "الإفطار", response.body
  end

  # The chip's label is words, never a flag: a flag is a country, and the
  # countries and the languages here do not line up — Arabic and Bosnian both
  # get it wrong.
  test "the control is labelled in words, in the reader's own language" do
    speaking_german
    translated_message("Doručak je od 07:00.", role: :staff, from: "bs", into: "de", as: "Das Frühstück ist ab 07:00.")
    sign_in_guest GUEST_TOKEN

    get guest_chat_path

    assert_select "button", text: I18n.t("guest.messages.translation.show_original", locale: :de)
  end

  private

  # The guest's *session* locale is what renders their surface
  # (GuestLocalization), and the conversation's is what the translator aims
  # at. Both have to say German or a test reads as if it passed.
  def speaking_german
    with_tenant(@hotel) do
      @guest_session.update!(locale: "de")
      @conversation.update!(guest_locale: "de")
    end
  end

  # Not `message` — Minitest::Assertions defines one, and overriding it makes
  # every assert_select in the file raise on its own failure message.
  def translated_message(body, role:, from:, into:, as:)
    with_tenant(@hotel) do
      @conversation.messages.create!(
        hotel: @hotel, sender_role: role, sender_user: (role == :staff ? @staff : nil),
        body: body, body_locale: from, translated_body: as, translated_locale: into,
        translation_status: :translated
      )
    end
  end
end
