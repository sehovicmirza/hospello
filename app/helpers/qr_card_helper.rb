# The words printed under the QR code on the card that goes in a hotel room.
#
# Deliberately not I18n. Every other guest-facing string is translated into the
# reader's own language, but this card has no reader yet — it is a piece of
# paper on a desk that has to speak to whoever picks it up, so it says the same
# thing in several languages at once, and the staff member printing it is not
# the audience. Putting these in config/locales would mean a card that printed
# in whatever language the receptionist happened to use.
#
# The set is Bosnian, English and Arabic: the hotels this is sold to are in
# Sarajevo, and Gulf visitors are a large share of their guests. German was
# dropped in 2026-08 — a fourth block earns its space only if the hotel
# actually sees those guests, and a crowded card is read by nobody. Dropping it
# from the card does not narrow the chat itself: the concierge answers in
# whatever language a guest writes in, German included
# (GuestLocaleHelper::SUPPORTED_LOCALES).
module QrCardHelper
  CardLine = Struct.new(:lang, :dir, :heading, :body, keyword_init: true)

  # What the card may honestly promise depends on the hotel's plan. On a plan
  # with service requests, scanning the code reaches the front desk and a guest
  # can ask for something. On Essentials it reaches an assistant that answers
  # questions about the hotel and nothing else — inviting a guest to "chat with
  # our front desk" would be a promise the product does not keep, printed and
  # left in the room where nobody can correct it.
  REQUESTS_LINES = [
    CardLine.new(lang: "bs", dir: nil,
      heading: "Trebate nešto? Samo pitajte.",
      body: "Skenirajte kod i pišite recepciji u bilo koje doba."),
    CardLine.new(lang: "en", dir: nil,
      heading: "Need anything? Just ask.",
      body: "Scan the code to chat with our front desk anytime."),
    CardLine.new(lang: "ar", dir: "rtl",
      heading: "هل تحتاج إلى شيء؟ فقط اسأل.",
      body: "امسح الرمز للتواصل مع الاستقبال في أي وقت.")
  ].freeze

  # Questions, not requests — and no mention of reaching a person, because on
  # this plan scanning the code does not. The reception number printed further
  # down the card is how a guest reaches one, which is exactly what the
  # assistant tells them too.
  QUESTIONS_LINES = [
    CardLine.new(lang: "bs", dir: nil,
      heading: "Imate pitanje? Samo pitajte.",
      body: "Skenirajte kod i pitajte bilo šta o hotelu."),
    CardLine.new(lang: "en", dir: nil,
      heading: "Have a question? Just ask.",
      body: "Scan the code to ask anything about the hotel."),
    CardLine.new(lang: "ar", dir: "rtl",
      heading: "لديك سؤال؟ اسأل ببساطة.",
      body: "امسح الرمز لتسأل أي شيء عن الفندق.")
  ].freeze

  def qr_card_lines(hotel)
    hotel.plan_allows?(:requests) ? REQUESTS_LINES : QUESTIONS_LINES
  end
end
