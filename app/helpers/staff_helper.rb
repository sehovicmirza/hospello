module StaffHelper
  # The topics guests ask about most, offered as one-click starters on an
  # empty knowledge base. The hardest part of starting one is the blank
  # sheet, and a hotel that never gets past it has a concierge that can
  # only ever say "I don't know" — so this list is a product feature, not
  # placeholder copy. `category` is a KbEntry category key (a machine value,
  # never shown); the visible/prefilled title comes from
  # config/locales/staff.*.yml (staff.kb_entries.starters — see
  # #kb_starter_title) so a Bosnian-speaking admin starts from a Bosnian
  # title, not an English one.
  KB_STARTERS = [
    { key: "breakfast", category: "dining" },
    { key: "check_out", category: "policies" },
    { key: "wifi", category: "facilities" },
    { key: "parking", category: "facilities" },
    { key: "spa", category: "facilities" },
    { key: "restaurant", category: "dining" },
    { key: "airport", category: "transport" }
  ].freeze

  def kb_starter_title(starter)
    t("staff.kb_entries.starters.#{starter[:key]}")
  end

  # Category names as a hotel manager would say them, not as the enum
  # spells them.
  def kb_category_label(category)
    t("staff.common.kb_categories.#{category}", default: category.to_s.humanize)
  end

  # A request category's detail field, named the way a receptionist would
  # say it rather than as RequestCategory::ALLOWED_DETAIL_FIELDS spells it.
  def staff_detail_field_label(field)
    t("staff.common.detail_fields.#{field}", default: field.to_s.humanize)
  end

  # A user's role (User#role), read wherever it is shown — the picker on
  # the new-staff form and the two read-only displays (the roster table,
  # one person's own page) all say the same word for "staff" or "hotel
  # admin" rather than each spelling the enum out itself.
  def staff_role_label(role)
    t("staff.common.roles.#{role}", default: role.to_s.humanize)
  end

  # Every timestamp rendered anywhere in the staff workspace goes through
  # this — a receptionist in Sarajevo must see Sarajevo time regardless of
  # where the server happens to run or what locale the browser is set to.
  def staff_time(time)
    time&.in_time_zone(Current.hotel.timezone)
  end

  # An attachment can be `attached?` while its blob is still an in-memory,
  # unsaved record: assigning a new file on a failed update (e.g. the record
  # re-renders :edit because an unrelated field is invalid) stages the
  # attachment change without persisting it. Generating a URL/signed_id for
  # that unsaved blob raises "Cannot get a signed_id for a new record" — this
  # is the guard every view that renders a hotel attachment must use instead
  # of a bare `attached?` check.
  def displayable_attachment?(attachment)
    attachment.attached? && attachment.blob.persisted?
  end

  # The single source of truth for the staff sidebar, shared by every staff
  # layout render. "Hotel settings" and "Staff" only appear for a user who
  # can actually reach them, so plain staff never see a link that would just
  # 403; Rooms and Departments & categories are read-only for plain staff
  # (RoomPolicy/DepartmentPolicy#index? allows it) so both appear for every
  # active staff user, not just hotel_admin. Staff accounts, unlike those
  # two, have no read access for plain staff at all (UserPolicy#index? is
  # hotel_admin-only), so the link is hotel_admin-only too. QR code follows
  # Rooms/Departments, not Staff: QrCodePolicy grants #show? to any active
  # staff member (receptionists reprint cards too) — instantiated directly
  # rather than via `policy(Current.hotel)`, which would resolve to
  # HotelPolicy (platform-admin-only) since Pundit infers the policy class
  # from the record's own class name, not from what this screen needs.
  def staff_nav_items
    items = [ { id: "dashboard", label: t("staff.nav.dashboard"), path: staff_root_path } ]
    # Inbox sits directly under Dashboard because it is the screen a
    # receptionist lives in, and it is the only nav item that carries a
    # count: noticing is half of what this product has to do for a busy
    # front desk. The badge is recomputed from the database on every render
    # and never incremented client-side, so it cannot drift away from what
    # is really waiting (see the plan's realtime section).
    if policy(Conversation).index?
      items << { id: "inbox", label: t("staff.nav.inbox"), path: staff_conversations_path, badge: staff_inbox_badge_count }
    end
    # Directly after Inbox: the knowledge base is the other thing a hotel
    # touches regularly once the concierge is live, and burying it is how a
    # hotel ends up with an assistant that knows nothing about them.
    # Directly under Inbox: requests are the other thing a receptionist works
    # a queue of, and the badge counts what nobody has picked up yet rather
    # than everything open — a number that never reaches zero is a number
    # nobody reads.
    if policy(ServiceRequest).index?
      items << { id: "requests", label: t("staff.nav.requests"), path: staff_service_requests_path, badge: staff_new_request_count }
    end
    items << { id: "kb", label: t("staff.nav.knowledge_base"), path: staff_kb_entries_path } if policy(KbEntry).index?
    # Immediately under the knowledge base, and badged, because this screen
    # only works if it is seen: the whole point is that a hotel discovers
    # what it never wrote down, and a hotel that never opens this discovers
    # nothing. Same server-computed rule as the inbox badge — nil rather
    # than 0, so the number always means something.
    if policy(UnansweredQuestion).index?
      items << { id: "knowledge-gaps", label: t("staff.nav.knowledge_gaps"), path: staff_unanswered_questions_path, badge: staff_knowledge_gap_count }
    end
    # Hotel admins only (HotelAnalyticsPolicy) — a receptionist reading
    # "how often did the assistant hand over to us" is reading a page
    # about their own performance, which is a conversation a manager
    # should choose to have rather than one the software starts.
    if HotelAnalyticsPolicy.new(Current.user, Current.hotel).analytics?
      items << { id: "analytics", label: t("staff.nav.analytics"), path: staff_analytics_path }
    end
    items << { id: "hotel-settings", label: t("staff.nav.hotel_settings"), path: edit_staff_hotel_settings_path } if policy(Current.hotel).edit?
    items << { id: "rooms", label: t("staff.nav.rooms"), path: staff_rooms_path } if policy(Room).index?
    # Next to the QR code at the bottom, not next to the inbox: this is the
    # hotel's *other* front door, configured once and then looked at only
    # when something is wrong with it.
    if policy(Current.hotel.whatsapp_channel || WhatsappChannel.new).show?
      items << { id: "whatsapp", label: t("staff.nav.whatsapp"), path: edit_staff_whatsapp_channel_path }
    end
    items << { id: "departments", label: t("staff.nav.departments"), path: staff_departments_path } if policy(Department).index?
    items << { id: "staff", label: t("staff.nav.staff"), path: staff_users_path } if policy(User).index?
    items << { id: "qr-code", label: t("staff.nav.qr_code"), path: staff_qr_code_path } if QrCodePolicy.new(Current.user, Current.hotel).show?

    items
  end

  # Who wrote a transcript entry, in words a receptionist can act on. The
  # guest is named rather than labelled "Guest" because the whole row is
  # about one person and repeating their name is how a long transcript
  # stays readable; staff are named individually because "who told the
  # guest that" is the question this screen gets asked most often.
  def staff_message_author(message)
    case message.sender_role
    when "guest" then message.conversation.guest_session.guest_name
    when "staff" then message.sender_user&.name || t("staff.common.message_authors.reception")
    when "assistant" then t("staff.common.message_authors.assistant")
    else t("staff.common.message_authors.system")
    end
  end

  # Colour is the *second* signal on a template's status, never the only one —
  # the word itself is rendered next to it (see the templates section), because
  # "waiting on Meta" and "refused by Meta" are different situations with
  # different next steps and a reader in a hurry must not have to decode a
  # colour to tell them apart.
  def whatsapp_template_status_classes(template)
    case template.status
    when "approved" then "bg-green-100 text-green-800"
    when "rejected" then "bg-red-100 text-red-800"
    else "bg-amber-100 text-amber-900"
    end
  end

  def staff_message_bubble_classes(message)
    case message.sender_role
    when "guest" then "bg-gray-100 text-gray-900"
    when "system" then "border border-dashed border-gray-300 bg-gray-50 italic text-gray-600"
    else "bg-blue-600 text-white" # staff, assistant — what the guest sees from the hotel
    end
  end

  # nil rather than 0 when nothing is waiting: a badge reading "0" is worse
  # than no badge, because it trains the eye to ignore the place the real
  # number will appear.
  def staff_inbox_badge_count
    count = Current.hotel.conversations.needs_attention.count
    count.positive? ? count : nil
  end

  # The persistent banner a receptionist sees whenever the assistant is not
  # answering guests — nil the rest of the time, so it is never wallpaper.
  #
  # It exists because the degradation path is deliberately invisible from the
  # guest's side: they are told a person will reply, and they are right. The
  # only way the front desk learns that "a person will reply" now means *them*,
  # for every guest, is if we say so here.
  #
  # Ordered from most to least fundamental, and only ever one is shown: a hotel
  # that has switched the assistant off does not also need to be told its
  # circuit breaker is open.
  def staff_ai_status_notice
    hotel = Current.hotel
    return nil if hotel.nil?

    if !hotel.ai_enabled?
      t("staff.common.ai_status.disabled")
    elsif Ai::CircuitBreaker.new(hotel).open?
      t("staff.common.ai_status.circuit_open")
    elsif AiRun.budget_exhausted_for?(hotel, fraction: 0.9)
      t("staff.common.ai_status.budget_exhausted")
    end
  end

  def staff_new_request_count
    count = Current.hotel.service_requests.status_new.count
    count.positive? ? count : nil
  end

  def staff_knowledge_gap_count
    count = Current.hotel.unanswered_questions.status_new.count
    count.positive? ? count : nil
  end

  # State in words, never colour alone — a colour-blind receptionist and a
  # printed screenshot both have to be readable. "New" rather than "pending"
  # because the board is a work queue, and the word a receptionist uses for
  # something nobody has picked up is "new".
  def staff_request_status_label(request)
    staff_status_label(request.status)
  end

  # Same reasoning as the request status above, for the conversation list's
  # own two settled states ("resolved"/"expired" — the only two
  # Conversation#status values ever shown as text, see
  # conversations/_conversation_row.html.erb and conversations/show.html.erb).
  # Not `.status.capitalize`: capitalizing an English enum value is still an
  # English word.
  def staff_conversation_status_label(conversation)
    t("staff.common.conversation_status.#{conversation.status}", default: conversation.status.humanize)
  end

  def staff_request_status_classes(request)
    case request.status
    when "new" then "bg-amber-100 text-amber-900"
    when "accepted", "in_progress" then "bg-blue-100 text-blue-900"
    when "completed" then "bg-green-100 text-green-900"
    else "bg-gray-100 text-gray-700"
    end
  end

  # How long it has been sitting there, in the words a receptionist would use
  # out loud rather than a timestamp they have to subtract from now.
  # time_ago_in_words is I18n-aware on its own (rails-i18n ships the
  # datetime.distance_in_words strings for :bs), so this needs no
  # translation of its own — only the "Waiting %{time}" wrapper around it
  # (staff.common.waiting) does.
  def staff_request_waiting_for(request)
    time_ago_in_words(request.created_at)
  end

  # Every transition this request can legally make, from the table on the
  # model. Rendering a button that would be refused is how a receptionist
  # learns to distrust the screen.
  def staff_request_transitions(request)
    labels = {
      "accepted" => t("staff.common.request_transitions.accepted"),
      "in_progress" => t("staff.common.request_transitions.in_progress"),
      "completed" => t("staff.common.request_transitions.completed"),
      "declined" => t("staff.common.request_transitions.declined"),
      "cancelled" => t("staff.common.request_transitions.cancelled")
    }

    ServiceRequest::TRANSITIONS.fetch(request.status, []).index_with { |to| labels.fetch(to) }
  end

  # The one or two a receptionist does dozens of times a shift, and nothing
  # else — a card crowded with five buttons is a card nobody reads.
  def staff_request_quick_transitions(request)
    quick = case request.status
    when "new" then %w[accepted]
    when "accepted", "in_progress" then %w[completed]
    else []
    end

    staff_request_transitions(request).slice(*quick)
  end

  def staff_request_event_sentence(event)
    who = event.user&.name || t("staff.common.request_event.automatically")

    if event.kind_status_change?
      t("staff.common.request_event.status_change",
        who: who,
        from: event.from_status_name && staff_status_label(event.from_status_name),
        to: event.to_status_name && staff_status_label(event.to_status_name))
    else
      t("staff.common.request_event.note_added", who: who)
    end
  end

  # "Unverified" is not a detail to be tucked away: the room number was
  # self-entered on a shared QR code, so every screen that shows a guest's
  # claimed identity has to say out loud that nobody checked it. Rendered
  # as text, never as colour or an icon alone.
  #
  # Unconditional, with no branch for the staff_verified half of the enum,
  # because there is currently no way to reach it: GuestSession's
  # before_save forces identity_status back to :unverified on *every* save,
  # deliberately (see that model). A branch here would be dead code that
  # reads like a promise this product does not yet make. Whoever builds
  # staff verification adds the branch then, along with the way in.
  def guest_identity_badge(_guest_session)
    tag.span t("staff.common.identity_badge.label"),
      class: "inline-flex items-center rounded-full bg-amber-50 px-2 py-0.5 text-xs font-semibold " \
             "text-amber-800 ring-1 ring-inset ring-amber-600/30",
      title: t("staff.common.identity_badge.tooltip")
  end

  # The one lookup behind both #staff_request_status_label (a request's own
  # status) and #staff_request_event_sentence (the from/to of a status
  # change in its history) — a receptionist should never see the same
  # status worded two different ways depending on which screen they are on.
  def staff_status_label(status)
    t("staff.common.request_status.#{status}", default: status.to_s.humanize)
  end
end
