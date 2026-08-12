require "test_helper"

# The registry that answers "is our welcome message usable yet?" without a
# hotel logging into Meta's dashboard.
#
# Everything here is about that sentence being honest. This table records
# Meta's decisions and makes none of them: `status` is a note of what Meta
# said, and #usable? is a cheap pre-check that saves a doomed API call, not a
# permission this app grants.
class WhatsappTemplateTest < ActiveSupport::TestCase
  setup do
    @hotel = hotels(:stari_grad)
    ActsAsTenant.current_tenant = @hotel
  end

  test "only an approved template can possibly be sent" do
    assert whatsapp_templates(:stari_welcome_bs).usable?
    assert_not whatsapp_templates(:stari_offer_bs).usable?
  end

  # `pending` is not "probably fine" — Meta refuses it outright, and a hotel
  # reading this screen needs the difference to be visible rather than
  # optimistic.
  test "a template still waiting on Meta is not usable" do
    pending = with_tenant(hotels(:vrelo)) { whatsapp_templates(:vrelo_welcome_de) }

    assert pending.status_pending?
    assert_not pending.usable?
  end

  test "a new template starts as pending, whatever anyone hoped" do
    template = @hotel.whatsapp_templates.create!(name: "checkout_reminder", locale: "bs")

    assert template.status_pending?
    assert template.category_utility?, "utility is the safe default — marketing is what restricts a number"
  end

  # --- Meta's own naming rule ---------------------------------------------
  #
  # Checked here so a hotel finds out while typing, rather than from a send
  # that fails hours later against a name Meta never had.

  test "a name Meta would refuse is refused here first" do
    [ "Welcome", "welcome message", "welcome-message", "welcome!" ].each do |name|
      template = @hotel.whatsapp_templates.new(name: name, locale: "bs")

      assert_not template.valid?, "#{name.inspect} is not a name Meta accepts"
      assert_includes template.errors[:name].to_sentence, "lowercase"
    end
  end

  # locale "en" rather than "bs": welcome/bs is a fixture, so on "bs" this
  # would fail on uniqueness and read as a format failure — the test would
  # then be red for a reason it does not name.
  test "the names Meta does accept are accepted" do
    %w[welcome welcome_message welcome_2 order_update_v2].each do |name|
      assert @hotel.whatsapp_templates.new(name: name, locale: "en").valid?, "#{name.inspect} should be allowed"
    end
  end

  test "a template with no language is refused — at Meta the language is half its identity" do
    assert_not @hotel.whatsapp_templates.new(name: "welcome").valid?
  end

  # --- Identity: name AND language ------------------------------------------

  test "the same name in another language is a different template, not a duplicate" do
    assert @hotel.whatsapp_templates.new(name: "welcome", locale: "en").valid?,
      "welcome/bs already exists; welcome/en is a separate object at Meta"
  end

  test "the same name in the same language is a duplicate" do
    duplicate = @hotel.whatsapp_templates.new(name: "welcome", locale: "bs")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name].to_sentence, "taken"
  end

  # The validation is the friendly error; the index is the guarantee. Proved
  # by switching validation off, the same shape whatsapp_channel_test.rb uses.
  test "the database itself refuses a duplicate, not merely the validation" do
    duplicate = @hotel.whatsapp_templates.new(name: "welcome", locale: "bs")

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  # Unlike phone_number_id, this is not a routing key: two hotels each having
  # their own "welcome" is the ordinary case, and refusing it would mean the
  # first hotel to register a common name took it from everyone else.
  test "two hotels may each have a template of the same name and language" do
    other = with_tenant(hotels(:vrelo)) do
      hotels(:vrelo).whatsapp_templates.new(name: "welcome", locale: "bs")
    end

    assert with_tenant(hotels(:vrelo)) { other.valid? }
    assert with_tenant(hotels(:vrelo)) { other.save }
  end

  # --- Tenancy ---------------------------------------------------------------

  test "a hotel sees only its own templates" do
    assert_equal %w[summer_offer welcome], WhatsappTemplate.ordered.pluck(:name)
    assert_equal %w[welcome], with_tenant(hotels(:vrelo)) { WhatsappTemplate.ordered.pluck(:name) }
  end

  # --- What Meta said, kept verbatim -----------------------------------------

  # Meta's vocabulary, not ours: a reason this app has never seen must still
  # be storable and readable rather than dropped or mapped onto a guess.
  test "Meta's own rejection reason is kept as it was given" do
    assert_equal "Template content violates promotional messaging policy",
                 whatsapp_templates(:stari_offer_bs).rejection_reason
  end

  # A language this app's own UI does not speak is still recordable — a hotel
  # unable to record a template is a hotel unable to explain why a send fails.
  test "a locale outside this app's own four is still recordable" do
    assert @hotel.whatsapp_templates.new(name: "welcome", locale: "pt_BR").valid?
  end
end
