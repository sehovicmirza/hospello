# View helpers shared by the guest chat (app/views/guest/chats,
# app/views/guest/messages) and by Conversation#broadcast_new_message,
# which renders guest/messages/_message outside of any controller action.
module GuestChatHelper
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
      *hotel.request_categories.active.ordered.map do |category|
        GuestQuickAction.new(
          label: category.name,
          prefill: t("guest.chats.quick_actions.category_prefill", category: category.name)
        )
      end,
      GuestQuickAction.new(
        label: t("guest.chats.quick_actions.contact_reception_label"),
        prefill: t("guest.chats.quick_actions.contact_reception_prefill")
      )
    ]
  end
end
