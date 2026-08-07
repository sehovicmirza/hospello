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
  # layout render. QR code still renders as an inert (unlinked) placeholder:
  # its controller arrives in a later task of this slice, and swapping
  # `path: nil` for a real path helper is the whole integration step once it
  # exists — nothing else about the nav changes. "Hotel settings" and "Staff"
  # only appear for a user who can actually reach them, so plain staff never
  # see a link that would just 403; Rooms and Departments & categories are
  # read-only for plain staff (RoomPolicy/DepartmentPolicy#index? allows it)
  # so both appear for every active staff user, not just hotel_admin. Staff
  # accounts, unlike those two, have no read access for plain staff at all
  # (UserPolicy#index? is hotel_admin-only), so the link is hotel_admin-only too.
  def staff_nav_items
    items = [ { label: "Dashboard", path: staff_root_path } ]
    items << { label: "Hotel settings", path: edit_staff_hotel_settings_path } if policy(Current.hotel).edit?
    items << { label: "Rooms", path: staff_rooms_path } if policy(Room).index?
    items << { label: "Departments & categories", path: staff_departments_path } if policy(Department).index?
    items << { label: "Staff", path: staff_users_path } if policy(User).index?

    items + [
      { label: "QR code", path: nil }
    ]
  end
end
