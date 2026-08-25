# View helpers shared by the guest chat (app/views/guest/chats,
# app/views/guest/messages) and by Conversation#broadcast_new_message,
# which renders guest/messages/_message outside of any controller action.
module GuestChatHelper
  # The wa.me deep link the landing page's "Chat on WhatsApp" button points
  # at — Meta's own click-to-chat form, which every WhatsApp client
  # understands and which needs no app-specific scheme.
  #
  # Two things it deliberately does not carry: the leading `+` (wa.me wants
  # digits only, and a `+` in the path silently produces a dead link), and
  # anything identifying. There is no token, no session and no guest id in
  # it — the room binding happens in conversation (Ai::Tools#set_guest_room),
  # so this URL is safe to print, screenshot or share, which is exactly what
  # people do with it.
  #
  # The greeting is prefilled so the guest's first message is one they chose
  # to send: Meta's 24-hour customer service window only opens once *they*
  # write, and a button that opens an empty chat leaves them staring at a
  # blank composer wondering what to say.
  def guest_whatsapp_url(hotel)
    channel = hotel.whatsapp_channel
    return nil if channel.nil?

    greeting = t("guest.entries.show.whatsapp_greeting", hotel_name: hotel.name)

    "https://wa.me/#{channel.phone_number_e164.to_s.delete('^0-9')}?text=#{CGI.escape(greeting)}"
  end

  # Every timestamp on the guest surface renders in the *hotel's* timezone
  # (spec requirement) — mirrors StaffHelper#staff_time, just keyed off the
  # hotel passed in rather than Current.hotel: Conversation#post_guest_message!
  # broadcasts by rendering this same partial from a background context
  # with no controller request (and so no Current.hotel) behind it at all,
  # so the timezone has to travel with the record being rendered instead.
  def guest_time(time, hotel)
    time&.in_time_zone(hotel.timezone)
  end

  # A locale-neutral 24-hour clock, deliberately not routed through
  # I18n/l(): rails-i18n does not ship full date/time formats for every one
  # of GuestLocaleHelper::SUPPORTED_LOCALES (notably bs), and digits alone
  # read correctly in all four without depending on that coverage.
  def guest_message_time(message)
    guest_time(message.created_at, message.hotel)&.strftime("%H:%M")
  end

  # Distinguishes guest / staff / system bubbles visually — paired in the
  # message partial with a text label (#guest_sender_label) so the
  # distinction never rests on colour alone.
  def guest_message_bubble_classes(message)
    case message.sender_role
    when "guest" then "text-white"
    when "system" then "border border-dashed border-gray-300 bg-gray-50 text-gray-600 italic"
    else "bg-gray-100 text-gray-900" # staff, assistant
    end
  end

  def guest_message_bubble_style(message)
    message.guest? ? "background-color:var(--brand-primary);color:var(--brand-on-primary);" : ""
  end

  # sr-only text label for the same distinction — screen readers get an
  # explicit "You" / "Hotel staff" / "System" regardless of bubble colour
  # or alignment. No "assistant" label: this slice never creates one (the
  # concierge arrives in Slice 3), so there is no AI-vocabulary label to
  # accidentally ship here.
  def guest_sender_label(message)
    t("guest.messages.sender_labels.#{message.sender_role}")
  end

  GuestQuickAction = Struct.new(:label, :prefill, keyword_init: true)

  # The chip list above the composer on an empty conversation (spec
  # requirement — see guest/chats/_quick_actions.html.erb): "ask a
  # question" first and "contact reception" last are fixed, always
  # present regardless of hotel; everything between them is this hotel's
  # own RequestCategory list, active-only, in the hotel's own configured
  # order. A category's prefill sentence wraps its *own* name verbatim —
  # RequestCategory#name is free text a hotel_admin typed (Slice 1), not
  # one of this app's four translated locale strings, so there is no
  # correct way to machine-translate it here; only the surrounding
  # sentence (t("guest.chats.quick_actions.category_prefill")) is in the
  # guest's own language.
  def guest_quick_actions(hotel)
    [
      GuestQuickAction.new(
        label: t("guest.chats.quick_actions.ask_question_label"),
        prefill: t("guest.chats.quick_actions.ask_question_prefill")
      ),
      *guest_quick_action_topics(hotel),
      GuestQuickAction.new(
        label: t("guest.chats.quick_actions.contact_reception_label"),
        prefill: t("guest.chats.quick_actions.contact_reception_prefill")
      )
    ]
  end

  # The middle chips, and the only part of the strip that depends on the plan.
  #
  # A hotel that takes requests offers its request categories, because tapping
  # "Extra towels" starts something the hotel can actually do. A hotel that does
  # not take requests must not offer them: the chip would be an invitation to
  # the one thing the assistant is going to refuse, and a guest who taps it gets
  # told to phone reception — a worse first impression than no chip at all.
  #
  # In its place, the hotel's own published knowledge base. Those make better
  # chips than a hand-written list would: they are the hotel's words, they are
  # already in the hotel's language like the category names they replace, and
  # every one of them is guaranteed answerable, because the knowledge base is
  # exactly what the assistant is allowed to answer from.
  #
  # Capped at five. These wrap onto their own rows on a 390px phone, and the
  # composer has to stay on screen (see test/system/guest_chat_mobile_test.rb).
  MAX_TOPIC_CHIPS = 5

  def guest_quick_action_topics(hotel)
    if hotel.plan_allows?(:requests)
      hotel.request_categories.active.ordered.map do |category|
        GuestQuickAction.new(
          label: category.name,
          prefill: t("guest.chats.quick_actions.category_prefill", category: category.name)
        )
      end
    else
      hotel.published_kb_entries.limit(MAX_TOPIC_CHIPS).map do |entry|
        GuestQuickAction.new(
          label: entry.title,
          prefill: t("guest.chats.quick_actions.topic_prefill", topic: entry.title)
        )
      end
    end
  end
end
