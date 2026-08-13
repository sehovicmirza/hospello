# ibis Styles Sarajevo — Accor, Dzemala Bijedica, five minutes from the airport.
#
# A real hotel, seeded as a pilot candidate. Facts marked SOURCED come from
# Accor's own page for the property. Everything marked INVENTED is plausible
# filler written to make the demo complete — what a hotel of this kind would
# plausibly say, not what this hotel has said. Nothing invented touches price
# or legal terms.
#
# The character to preserve: an international brand rather than an independent
# house — named outlets (1984 Restaurant, Igman Bar), a big conference floor,
# free wifi and parking as standard, and guests who are here for one night
# between flights. This is also the one hotel whose staff workspace is in
# English rather than Bosnian, which puts the per-user locale work on screen.

module DemoCatalogue
  def self.ibis_styles
    {
      hotel: {
        name: "ibis Styles Sarajevo",
        slug: "ibis-styles-sarajevo",
        timezone: "Europe/Sarajevo",
        # The one demo hotel whose staff read the workspace in English — an
        # international operator with a mixed team. Reception staff below are
        # still a mix, because User#locale is per person.
        staff_locale: "en",
        primary_color: "#0A3A6B",
        secondary_color: "#E4572E",
        concierge_name: "Maja",
        welcome_message: "Welcome to ibis Styles Sarajevo! Ask me anything — breakfast, the airport, parking, or what to see in town.",
        contact_phone: "+387 33 483-900", # SOURCED: all.accor.com
        checkout_time: "12:00",           # SOURCED: check-out up to 12:00
        contact_notes: "Reception is open 24 hours. In an emergency call 122 (police) or 124 (ambulance).",
        overdue_after_minutes: 120
      },

      admin: { name: "Nina Popović", email: "admin@ibis-sarajevo.demo", locale: "en" },
      reception: [
        { name: "Kenan Alispahić", email: "kenan@ibis-sarajevo.demo", locale: "bs" },
        { name: "Sofia Lindqvist", email: "sofia@ibis-sarajevo.demo", locale: "en" },
        { name: "Dženana Fazlić", email: "dzenana@ibis-sarajevo.demo", locale: "bs" }
      ],

      room_numbers: (401..414).to_a + (501..514).to_a,

      departments: {
        housekeeping: "Housekeeping",
        front_desk: "Front desk",
        kitchen: "1984 Restaurant",
        conference: "Conference & events",
        maintenance: "Maintenance"
      },

      categories: {
        towels: { department: :housekeeping, key: "room_items", name: "Towels and bedding",
                  detail_fields: %w[quantity description] },
        cleaning: { department: :housekeeping, key: "cleaning", name: "Room cleaning",
                    detail_fields: %w[time description] },
        room_service: { department: :kitchen, key: "room_service", name: "Room service",
                        detail_fields: %w[description time people] },
        restaurant: { department: :kitchen, key: "restaurant_booking", name: "Table reservation",
                      detail_fields: %w[time people description] },
        conference: { department: :conference, key: "conference_support", name: "Meeting room support",
                      detail_fields: %w[time people description] },
        taxi: { department: :front_desk, key: "taxi", name: "Taxi and airport transfer",
                detail_fields: %w[time people description] },
        late_checkout: { department: :front_desk, key: "late_checkout", name: "Late check-out",
                         detail_fields: %w[time description] },
        repair: { department: :maintenance, key: "maintenance", name: "Something broken in the room",
                  detail_fields: %w[description] }
      },

      # Written in Bosnian like the other hotels: the concierge answers in
      # whichever language the guest writes in, so one knowledge base serves all
      # four guest languages regardless of what the staff workspace is set to.
      knowledge: [
        # SOURCED: 1984 Restaurant, Igman Bar, Chill Cafe, Ibis Cake Gallery.
        { category: :dining, title: "Restoran 1984",
          content: "Naš restoran se zove 1984 — po Zimskim olimpijskim igrama u Sarajevu. Tu se služi " \
                   "doručak, a uveče à la carte meni." },
        { category: :dining, title: "Igman bar i Chill Cafe",
          content: "Igman bar i Chill Cafe su u prizemlju hotela. Igman bar radi do kasno, a Chill Cafe " \
                   "je mjesto gdje gosti obično rade ili čekaju prevoz." }, # hours INVENTED
        { category: :dining, title: "Ibis Cake Gallery",
          content: "Ibis Cake Gallery je naš slastičarski kutak — kolači i kafa tokom cijelog dana." },
        { category: :dining, title: "Doručak",
          content: "Doručak se služi u restoranu 1984 od 06:00 do 10:00, a vikendom do 10:30. Ako imate " \
                   "rani let, javite recepciji večer prije i spakujemo vam doručak za ponijeti." }, # hours INVENTED
        { category: :dining, title: "Posluga u sobu",
          content: "Posluga u sobu dostupna je od 07:00 do 23:00. Meni je u sobi." }, # INVENTED
        # SOURCED: free WiFi.
        { category: :facilities, title: "Wi-Fi",
          content: "Besplatan Wi-Fi u cijelom hotelu, bez ograničenja. Mreža i lozinka su na kartici " \
                   "koju dobijete pri prijavi." },
        # SOURCED: free parking.
        { category: :facilities, title: "Parking",
          content: "Parking je besplatan za goste hotela. Ako dolazite kombijem ili autobusom, javite " \
                   "recepciji unaprijed." },
        # SOURCED: conference space for up to 800 guests.
        { category: :facilities, title: "Konferencijske sale",
          content: "Hotel ima konferencijske kapacitete za do 800 osoba, u više sala različite veličine. " \
                   "Ako ste ovdje zbog skupa, recepcija ima raspored sala." },
        { category: :facilities, title: "Teretana",
          content: "Teretana je dostupna gostima hotela. Radno vrijeme i pristup provjerite na " \
                   "recepciji." }, # INVENTED
        # SOURCED: 181 rooms; A/C, tea and coffee facilities, flat-screen TV,
        # minibar, hairdryer, bathrobes.
        { category: :rooms, title: "Sobe",
          content: "Hotel ima 181 sobu. Sve su klimatizovane i imaju aparat za čaj i kafu, televizor, " \
                   "mini bar, fen za kosu i bade mantile." },
        { category: :rooms, title: "Dodatni ležaj i krevetac",
          content: "Dodatni ležaj je moguć u dijelu soba uz najavu. Krevetac za bebe je besplatan — " \
                   "zatražite ga pri prijavi." }, # INVENTED
        { category: :rooms, title: "Nepušačke sobe",
          content: "Sve sobe su nepušačke. Pušenje je dozvoljeno na označenim mjestima ispred hotela." }, # INVENTED
        # SOURCED: check-in from 15:00, check-out up to 12:00.
        { category: :policies, title: "Prijava i odjava",
          content: "Prijava je od 15:00, a odjava do 12:00. Ako stižete ranije ili odlazite kasnije, " \
                   "prtljag čuvamo na recepciji besplatno." },
        { category: :policies, title: "Kasna odjava",
          content: "Kasna odjava je moguća ovisno o popunjenosti. Pitajte recepciju na dan odlaska ili " \
                   "me pitajte odavde pa ću provjeriti." }, # INVENTED
        { category: :policies, title: "Kućni ljubimci",
          content: "Kućni ljubimci su dobrodošli uz prethodnu najavu." }, # INVENTED
        { category: :policies, title: "Otkazivanje",
          content: "Uslovi otkazivanja zavise od tarife po kojoj ste rezervisali. Recepcija vam može " \
                   "provjeriti šta važi za vašu rezervaciju." }, # INVENTED, deliberately non-committal
        # SOURCED: 5 min drive from Sarajevo International Airport.
        { category: :transport, title: "Aerodrom",
          content: "Međunarodni aerodrom Sarajevo je oko 5 minuta vožnje od hotela. Taksi možemo " \
                   "pozvati u bilo koje doba — recite mi vrijeme leta." },
        # SOURCED: close to Alipašino Polje; near the city centre.
        { category: :transport, title: "Do centra grada",
          content: "Hotel je na Džemala Bijedića, blizu Alipašinog Polja. Do centra i Baščaršije se " \
                   "ide tramvajem ili taksijem — tramvajska stanica je u blizini." },
        { category: :transport, title: "Tramvaj",
          content: "Tramvaj vozi od Ilidže do Baščaršije i staje blizu hotela. Karta se kupuje na " \
                   "kiosku ili kod vozača i poništava se u vozilu." }, # INVENTED detail
        { category: :local_area, title: "Gdje se nalazimo",
          content: "Adresa je Džemala Bijedića 169A. Hotel je između aerodroma i centra grada, što " \
                   "odgovara i poslovnim gostima i onima koji su tu jednu noć između letova." },
        { category: :local_area, title: "Šta vidjeti",
          content: "Baščaršija, Vijećnica i Latinska ćuprija su u centru — tramvajem oko 25 minuta. " \
                   "Tunel spasa je blizu aerodroma, desetak minuta odavde." }, # INVENTED
        { category: :facilities, title: "Nova sala za sastanke (u pripremi)",
          content: "NACRT — ne objavljivati dok se ne potvrdi kapacitet.",
          published: false, position: 99 }
      ],

      conversations: [
        { key: :bosnian,
          guest: { name: "Tarik Bečirović", locale: "bs", room: "406", days_ago: 2 },
          status: :resolved, last_message_minutes_ago: 2_700, staff_unread_count: 0,
          messages: [
            { role: :guest, body: "Dobar dan, je li parking besplatan i ima li mjesta?", minutes_ago: 2_705 },
            { role: :assistant, minutes_ago: 2_704,
              body: "Dobar dan! Da, parking je besplatan za goste hotela. Mjesta obično ima — ako " \
                    "dolazite kombijem ili s grupom, javite recepciji unaprijed." },
            { role: :guest, body: "Super, hvala.", minutes_ago: 2_700 }
          ] },

        { key: :english,
          guest: { name: "Priya Raman", locale: "en", room: "509", days_ago: 1 },
          last_message_minutes_ago: 900, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 906,
              body: "I land late tonight and fly out at 07:00. Is breakfast open early enough, and can you book me a taxi?" },
            { role: :assistant, minutes_ago: 905,
              body: "Breakfast in the 1984 Restaurant starts at 06:00, which is tight for a 07:00 " \
                    "flight — the airport is only five minutes away, but check-in closes earlier. I'd " \
                    "suggest a packed breakfast and a taxi at 05:15. Shall I arrange both?" },
            { role: :guest, body: "Yes, that's perfect. Thank you.", minutes_ago: 902 },
            { role: :assistant, minutes_ago: 900,
              body: "Both sent to reception — pending until they confirm. The packed breakfast will be " \
                    "at the front desk." }
          ] },

        { key: :german,
          guest: { name: "Stefan Achleitner", locale: "de", room: "412", days_ago: 1 },
          status: :escalated, escalation_reason: :guest_requested, escalated_minutes_ago: 350,
          last_message_minutes_ago: 210, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 355,
              body: "Ich brauche eine Rechnung auf die Firma, mit Steuernummer. Können Sie das ausstellen?" },
            { role: :assistant, minutes_ago: 351,
              body: "Rechnungen stellt die Rezeption aus, nicht ich — dafür brauchen wir Ihre " \
                    "Firmendaten. Ich habe die Rezeption informiert, sie meldet sich persönlich bei Ihnen." },
            { role: :system, minutes_ago: 350, visibility: :internal,
              body: "The assistant handed this over (guest requested): company invoice with tax number. " \
                    "Billing — never handled by the assistant." },
            { role: :staff, minutes_ago: 210, locale: "en", user: :reception_1,
              body: "Guten Tag, Herr Achleitner — senden Sie uns bitte die Firmendaten, wir stellen die " \
                    "Rechnung heute noch aus." }
          ] },

        { key: :arabic,
          guest: { name: "فاطمة الزهراني", locale: "ar", room: "503", days_ago: 1,
                   phone: "+38762447788", channel: :whatsapp },
          last_message_minutes_ago: 130, staff_unread_count: 1,
          messages: [
            { role: :guest, body: "مرحباً، كم تبعد الفندق عن المطار؟ ووصلت متأخرة، هل الإفطار متاح؟", minutes_ago: 136 },
            { role: :assistant, minutes_ago: 135,
              body: "أهلاً بك! الفندق يبعد نحو خمس دقائق بالسيارة عن مطار سراييفو الدولي. الإفطار يُقدم " \
                    "في مطعم 1984 من الساعة 06:00 حتى 10:00، وحتى 10:30 في عطلة نهاية الأسبوع." },
            { role: :guest, body: "ممتاز، شكراً", minutes_ago: 130 }
          ] },

        { key: :waiting,
          guest: { name: "Lukas Neuwirth", locale: "en", room: "414", days_ago: 0 },
          last_message_minutes_ago: 10, last_guest_message_minutes_ago: 10, staff_unread_count: 1,
          messages: [
            { role: :guest, minutes_ago: 10,
              body: "Is there a meeting room free tomorrow morning for six people? We only need an hour." }
          ] }
      ],

      requests: [
        { category: :taxi, conversation: :english, status: :accepted, minutes_ago: 900,
          summary: "Taxi — airport, 05:15",
          details: { "time" => "05:15", "people" => "1", "description" => "flight at 07:00" },
          acknowledged_minutes_ago: 880, acknowledged_by: :reception_1 },

        { category: :room_service, conversation: :english, status: :in_progress, minutes_ago: 890,
          summary: "Room service — packed breakfast for an early flight",
          details: { "description" => "packed breakfast, leave at front desk", "time" => "05:00", "people" => "1" },
          acknowledged_minutes_ago: 870, acknowledged_by: :reception_0 },

        { category: :towels, conversation: :bosnian, status: :completed, minutes_ago: 2_600,
          summary: "Towels and bedding — one extra pillow",
          details: { "quantity" => "1", "description" => "extra pillow" },
          acknowledged_minutes_ago: 2_580, acknowledged_by: :reception_2, completed_minutes_ago: 2_500 },

        { category: :conference, conversation: :arabic, status: :new, minutes_ago: 35,
          summary: "Meeting room support — projector and water",
          details: { "time" => "09:00", "people" => "12", "description" => "projector, water, flip chart" } },

        { category: :late_checkout, conversation: :german, status: :declined, minutes_ago: 640,
          summary: "Late check-out — until 16:00",
          details: { "time" => "16:00", "description" => "hotel full, room needed for arriving group" },
          acknowledged_minutes_ago: 630, acknowledged_by: :admin },

        { category: :restaurant, conversation: :english, status: :cancelled, minutes_ago: 450,
          summary: "Table reservation — dinner for two, 20:00",
          details: { "time" => "20:00", "people" => "2", "description" => "guest ate at the airport instead" } },

        # Older than this hotel's 120-minute threshold and unclaimed.
        { category: :repair, conversation: :bosnian, status: :new, minutes_ago: 280,
          summary: "Something broken in the room — TV has no signal",
          details: { "description" => "no signal on the TV in room 406, reported this afternoon" } }
      ],

      unanswered: [
        { question: "Is there a meeting room available at short notice?", original: nil, locale: "en", times: 4 },
        { question: "Does the hotel have an airport shuttle, or only taxis?",
          original: "Hat das Hotel einen Flughafen-Shuttle?", locale: "de", times: 3 },
        { question: "Is there a prayer room in the hotel?",
          original: "هل يوجد مصلى في الفندق؟", locale: "ar", times: 2 }
      ],

      usage_history_days: 10
    }
  end
end
