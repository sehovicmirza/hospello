module StaffHelper
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
    items = [ { label: "Dashboard", path: staff_root_path } ]
    # Inbox sits directly under Dashboard because it is the screen a
    # receptionist lives in, and it is the only nav item that carries a
    # count: noticing is half of what this product has to do for a busy
    # front desk. The badge is recomputed from the database on every render
    # and never incremented client-side, so it cannot drift away from what
    # is really waiting (see the plan's realtime section).
    if policy(Conversation).index?
      items << { label: "Inbox", path: staff_conversations_path, badge: staff_inbox_badge_count }
    end
    items << { label: "Hotel settings", path: edit_staff_hotel_settings_path } if policy(Current.hotel).edit?
    items << { label: "Rooms", path: staff_rooms_path } if policy(Room).index?
    items << { label: "Departments & categories", path: staff_departments_path } if policy(Department).index?
    items << { label: "Staff", path: staff_users_path } if policy(User).index?
    items << { label: "QR code", path: staff_qr_code_path } if QrCodePolicy.new(Current.user, Current.hotel).show?

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
    when "staff" then message.sender_user&.name || "Reception"
    when "assistant" then "Assistant"
    else "System"
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
    tag.span "UNVERIFIED",
      class: "inline-flex items-center rounded-full bg-amber-50 px-2 py-0.5 text-xs font-semibold " \
             "text-amber-800 ring-1 ring-inset ring-amber-600/30",
      title: "The guest typed this name and room number themselves — nobody has checked them."
  end
end
