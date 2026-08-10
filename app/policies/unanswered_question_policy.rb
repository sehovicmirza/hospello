# Read for everyone on the staff, act on it for hotel admins only — the same
# split HotelConfigurationPolicy already encodes, subclassed here so Pundit's
# class-name inference keeps working (same reasoning as KbEntryPolicy).
#
# The read half matters more than it looks. A receptionist answering the same
# question by hand for the fourth time this week is the person best placed to
# notice it belongs in the knowledge base, and a screen they cannot open is a
# screen that never gets acted on. Writing the answer down, though, is
# changing what the hotel tells guests, which is a hotel_admin decision — the
# same line the knowledge base itself draws.
class UnansweredQuestionPolicy < HotelConfigurationPolicy
  # Dismissing is a write: it decides this hotel will not answer something,
  # and a repeat asking will not undo it.
  def dismiss?
    update?
  end
end
