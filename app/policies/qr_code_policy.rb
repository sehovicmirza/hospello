# The hotel's QR code page and printable sheet: no create/update/destroy
# endpoint exists at all (there is nothing to write — see HotelQrCode), so
# this only ever answers #show? (the on-screen page and its .svg/.png
# downloads) and #print? (the printable sheet). Both use the same rule
# HotelConfigurationPolicy already grants for reading rooms/departments/
# categories — any active staff member, not just a hotel_admin — because a
# receptionist reprinting a lost or damaged card is exactly what this screen
# is for, not an admin-only action.
class QrCodePolicy < HotelConfigurationPolicy
  def print?
    active_staff?
  end
end
