module ApplicationHelper
  # The dialable form of a hotel's reception number, for a `tel:` href.
  #
  # This is the link under "the chat is not an emergency channel — call
  # reception", so it is the one a guest taps when something has actually gone
  # wrong. It has to survive whatever a hotel admin typed into the settings
  # form: `+387 33 483-900` and `+387 (33) 483 900` are both things people
  # write, and both were previously passed through with only whitespace
  # stripped, leaving the punctuation in the href.
  #
  # RFC 3966 does permit visual separators, and phones do cope — this is
  # robustness rather than a live bug. But three views were each doing their
  # own `gsub(/\s+/, "")`, which is three places for the next format to be
  # half-handled.
  #
  # Everything except digits is dropped, and a leading `+` is preserved because
  # it is what makes an international number dialable from abroad — which is
  # most of this product's guests.
  def dialable_phone(phone)
    digits = phone.to_s.gsub(/[^0-9]/, "")
    return "" if digits.blank?

    phone.to_s.strip.start_with?("+") ? "+#{digits}" : digits
  end
end
