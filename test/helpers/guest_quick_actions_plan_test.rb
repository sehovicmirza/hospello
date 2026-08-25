require "test_helper"

# The chip strip under an empty guest chat, which is the first thing a guest
# sees and the only steering the product does before they type.
#
# The plan changes what belongs there. On Service the middle chips are the
# hotel's request categories, because tapping "Extra towels" starts something
# the hotel can do. On Essentials that same chip is an invitation to the one
# thing the assistant will refuse, so the chips become the hotel's own
# published knowledge base — guaranteed answerable, because that is exactly
# what the assistant answers from.
class GuestQuickActionsPlanTest < ActionView::TestCase
  include GuestChatHelper

  setup do
    @hotel = hotels(:stari_grad)
    ActsAsTenant.current_tenant = @hotel
  end

  test "a Service hotel offers its request categories" do
    @hotel.update!(plan: :service)

    labels = guest_quick_actions(@hotel).map(&:label)

    assert_includes labels, "Extra towels, bedding or toiletries"
    assert_includes labels, "Wake-up call"
  end

  test "an Essentials hotel offers no request category as a chip" do
    @hotel.update!(plan: :essentials)

    labels = guest_quick_actions(@hotel).map(&:label)

    assert_not_includes labels, "Extra towels, bedding or toiletries"
    assert_not_includes labels, "Wake-up call"
  end

  test "an Essentials hotel offers its published knowledge base instead" do
    @hotel.update!(plan: :essentials)

    labels = guest_quick_actions(@hotel).map(&:label)

    # The fixtures' published entries for this hotel.
    assert_includes labels, "Breakfast"
    assert_includes labels, "Wi-Fi"
  end

  # A draft is not something the assistant may answer from, so offering it as a
  # chip would promise an answer that cannot come.
  test "an unpublished entry is never offered as a chip" do
    @hotel.update!(plan: :essentials)
    draft = @hotel.kb_entries.create!(title: "Secret rooftop", content: "Not live yet",
                                      category: "facilities", published: false)

    assert_not_includes guest_quick_actions(@hotel).map(&:label), draft.title
  end

  # These wrap onto their own rows on a 390px phone and the composer has to stay
  # on screen — see test/system/guest_chat_mobile_test.rb.
  test "the topic chips are capped so the composer stays on screen" do
    @hotel.update!(plan: :essentials)
    10.times { |i| @hotel.kb_entries.create!(title: "Topic #{i}", content: "x", category: "facilities", published: true) }

    # Two framing chips (ask a question, contact reception) plus the cap.
    assert_equal GuestChatHelper::MAX_TOPIC_CHIPS + 2, guest_quick_actions(@hotel).size
  end

  test "both plans keep the ask-a-question and contact-reception chips" do
    %i[essentials service].each do |plan|
      @hotel.update!(plan: plan)

      labels = guest_quick_actions(@hotel).map(&:label)

      assert_equal "Ask a question", labels.first, "#{plan} lost the opening chip"
      assert_equal "Contact reception", labels.last, "#{plan} lost the reception chip"
    end
  end
end
