# Read for everyone on the staff, write for hotel admins only — the same
# split KbEntryPolicy and friends already encode, so this subclasses the
# shared policy rather than restating it.
#
# Why a receptionist may read but not write: the number, its status and its
# last error are exactly what someone at the desk needs when a guest says
# "I messaged you on WhatsApp and nobody answered" — that is a shift
# question, not a configuration one. Changing the number is the opposite: it
# is the hotel's own published asset, and a wrong `phone_number_id` silently
# routes that hotel's guests nowhere (see WhatsappChannel).
class WhatsappChannelPolicy < HotelConfigurationPolicy
end
