# Read for everyone on the staff, write for hotel admins only — the exact
# split HotelConfigurationPolicy already encodes, so this subclasses it
# rather than restating it (same reasoning as RoomPolicy and friends: the
# subclass exists so Pundit's class-name inference keeps working, and so
# this can diverge later without dragging the others with it).
#
# Why a receptionist may read but not write: the knowledge base is what the
# concierge tells guests on the hotel's behalf, so editing it mid-shift is
# changing hotel policy — but a receptionist absolutely has to be able to
# look up what the hotel has already promised, since they are answering the
# same questions by hand.
#
# #publish? is separate from #update? even though both currently mean
# "hotel admin": publishing is the act that puts text in front of guests,
# and a task that later wants a four-eyes rule or an audited approval step
# should have somewhere obvious to put it.
class KbEntryPolicy < HotelConfigurationPolicy
  def publish?
    update?
  end
end
