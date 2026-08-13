# Hotel Vema — Visoko, 32 km from Sarajevo.
#
# A real hotel, seeded as a pilot candidate. Facts marked SOURCED come from
# hotelvema.ba. Everything marked INVENTED is plausible filler written to make
# the demo complete — what a hotel of this kind would plausibly say, not what
# this hotel has said. Nothing invented touches price or legal terms.
#
# The character to preserve: the smallest and most personal of the four, and
# the only one outside Sarajevo. Free parking, a spa, and a restaurant that
# does pizza — a town hotel where guests arrive by car, plus the pyramid
# visitors Visoko gets. Distance to the city is the thing guests ask about.

module DemoCatalogue
  def self.hotel_vema
    {
      hotel: {
        name: "Hotel Vema Visoko",
        slug: "hotel-vema-visoko",
        timezone: "Europe/Sarajevo",
        staff_locale: "bs",
        primary_color: "#2E4A7D",
        secondary_color: "#C08A2E",
        concierge_name: "Ajla",
        welcome_message: "Dobrodošli u Hotel Vema! Pitajte me bilo šta — doručak, spa, parking, put do Sarajeva.",
        contact_phone: "+387 32 731 000", # SOURCED: hotelvema.ba
        checkout_time: "11:00",           # SOURCED: check-out at 11:00
        contact_notes: "Recepcija radi 24 sata. Za hitne slučajeve zovite 122 (policija) ili 124 (hitna pomoć).",
        overdue_after_minutes: 90
      },

      admin: { name: "Nermin Bašić", email: "admin@vema.demo", locale: "bs" },
      reception: [
        { name: "Alma Hadžić", email: "alma@vema.demo", locale: "bs" },
        { name: "Tarik Omerović", email: "tarik@vema.demo", locale: "bs" },
        { name: "Ena Kadrić", email: "ena@vema.demo", locale: "en" }
      ],

      # A smaller house: two floors and a handful of family rooms.
      room_numbers: (101..112).to_a + (201..210).to_a,

      departments: {
        housekeeping: "Domaćinstvo",
        front_desk: "Recepcija",
        spa: "Wellness i spa",
        kitchen: "Restoran",
        maintenance: "Održavanje"
      },

      categories: {
        towels: { department: :housekeeping, key: "room_items", name: "Peškiri i posteljina",
                  detail_fields: %w[quantity description] },
        cleaning: { department: :housekeeping, key: "cleaning", name: "Čišćenje sobe",
                    detail_fields: %w[time description] },
        room_service: { department: :kitchen, key: "room_service", name: "Posluga u sobu",
                        detail_fields: %w[description time people] },
        restaurant: { department: :kitchen, key: "restaurant_booking", name: "Rezervacija stola",
                      detail_fields: %w[time people description] },
        spa_booking: { department: :spa, key: "spa_booking", name: "Wellness — termin",
                       detail_fields: %w[time people description] },
        taxi: { department: :front_desk, key: "taxi", name: "Prevoz i taksi",
                detail_fields: %w[time people description] },
        late_checkout: { department: :front_desk, key: "late_checkout", name: "Kasna odjava",
                         detail_fields: %w[time description] },
        repair: { department: :maintenance, key: "maintenance", name: "Kvar u sobi",
                  detail_fields: %w[description] }
      },

      knowledge: [
        # SOURCED: restaurant + 2 cafés; local, international and vegetarian
        # cuisine including pizza; buffet breakfast.
        { category: :dining, title: "Restoran",
          content: "Naš restoran je porodičan i nudi domaću, internacionalnu i vegetarijansku kuhinju, " \
                   "uključujući pizzu. U hotelu su i dva kafića." },
        { category: :dining, title: "Doručak",
          content: "Doručak je švedski sto i služi se svako jutro od 07:00 do 10:00. Uključen je u " \
                   "cijenu sobe. Ako putujete ranije, javite večer prije i pripremimo vam nešto za " \
                   "ponijeti." }, # hours INVENTED — buffet breakfast is SOURCED
        { category: :dining, title: "Posluga u sobu",
          content: "Posluga u sobu radi od 08:00 do 22:00. Meni je u sobi, a narudžbu možete predati i " \
                   "ovdje u chatu." }, # INVENTED
        { category: :dining, title: "Rezervacija stola",
          content: "Za večeru vikendom preporučujemo rezervaciju — recite mi termin i broj osoba pa ću " \
                   "poslati zahtjev restoranu." }, # INVENTED
        # SOURCED: wellness & spa, sauna, fitness, indoor pool, hot tub,
        # terrace and garden; Swedish massage mentioned by aggregators.
        { category: :facilities, title: "Wellness i spa",
          content: "Hotel ima wellness i spa centar sa saunom, zatvorenim bazenom i jacuzzijem, te " \
                   "teretanu. Za masažu preporučujemo raniju najavu — mogu vam dogovoriti termin." },
        { category: :facilities, title: "Bazen",
          content: "Zatvoreni bazen je dostupan gostima hotela. Peškire za bazen dobijate u wellness " \
                   "centru." }, # hours INVENTED
        { category: :facilities, title: "Terasa i bašta",
          content: "Hotel ima terasu i baštu sa vanjskim sjedenjem — ljeti je to najprijatniji dio " \
                   "hotela, posebno ujutro." }, # SOURCED that they exist; framing INVENTED
        # SOURCED: free parking in front of the hotel.
        { category: :facilities, title: "Parking",
          content: "Ispred hotela je parking za sve naše goste, besplatan. Ako dolazite kombijem ili " \
                   "autobusom, javite recepciji unaprijed." },
        # SOURCED: Wi-Fi throughout the hotel, for all guests.
        { category: :facilities, title: "Wi-Fi",
          content: "Bežični internet je dostupan svim gostima u cijelom hotelu. Lozinku dobijate pri " \
                   "prijavi, a možete je pitati i ovdje." },
        # SOURCED: A/C, soundproofed, balcony or terrace, some with kitchenette,
        # minibar, desk, safe; accessible and non-smoking options.
        { category: :rooms, title: "Sobe",
          content: "Sobe imaju klimu, zvučnu izolaciju, balkon ili terasu, radni sto, mini bar i sef. " \
                   "Neke sobe imaju i čajnu kuhinju sa pločom za kuhanje." },
        { category: :rooms, title: "Porodične sobe",
          content: "Imamo porodične sobe sa vlastitim kupatilom. Dodatni ležaj i krevetac za bebe su " \
                   "mogući uz najavu." }, # family rooms SOURCED; the rest INVENTED
        { category: :rooms, title: "Pristupačnost",
          content: "Hotel ima sobe prilagođene osobama sa invaliditetom i lift do svih spratova. Ako " \
                   "vam treba nešto konkretno, javite unaprijed pa da pripremimo." },
        { category: :rooms, title: "Nepušačke sobe",
          content: "Sve sobe su nepušačke. Pušenje je moguće na balkonu ili u bašti." }, # INVENTED
        # SOURCED: check-in 14:00, check-out 11:00, early/late may carry a charge.
        { category: :policies, title: "Prijava i odjava",
          content: "Prijava je od 14:00, a odjava do 11:00. Raniji dolazak ili kasniji odlazak su mogući " \
                   "uz eventualnu doplatu i ovisno o popunjenosti — pitajte recepciju." },
        { category: :policies, title: "Kućni ljubimci",
          content: "Kućni ljubimci su mogući uz prethodnu najavu — javite nam vrstu i veličinu pri " \
                   "rezervaciji." }, # INVENTED
        { category: :policies, title: "Otkazivanje",
          content: "Uslovi otkazivanja zavise od načina rezervacije. Recepcija vam može provjeriti šta " \
                   "važi za vašu rezervaciju." }, # INVENTED, deliberately non-committal on terms
        # SOURCED: 32 km from Sarajevo, ~30 min to the airport.
        { category: :transport, title: "Do Sarajeva i aerodroma",
          content: "Visoko je 32 km od Sarajeva. Do aerodroma se vozi oko pola sata. Ako vam treba " \
                   "prevoz, recepcija ga može organizovati — recite mi vrijeme i broj osoba." },
        { category: :transport, title: "Dolazak automobilom",
          content: "Hotel je uz glavni put kroz Visoko, a parking ispred hotela je besplatan. Većina " \
                   "gostiju dolazi autom." }, # INVENTED framing on SOURCED facts
        { category: :transport, title: "Autobus i voz",
          content: "Autobuska stanica u Visokom je blizu hotela. Za tačan red vožnje pitajte recepciju — " \
                   "mijenja se sezonski." }, # INVENTED
        # SOURCED: ~0.3 mi from the centre of Visoko.
        { category: :local_area, title: "Gdje se nalazimo",
          content: "Hotel je na adresi Branilaca Bosne bb, nekoliko minuta hoda od centra Visokog." },
        { category: :local_area, title: "Visočke piramide",
          content: "Bosanska piramida Sunca je iznad grada i najčešći je razlog zbog kojeg gosti dolaze " \
                   "u Visoko. Uspon traje oko sat vremena. Obucite obuću za hodanje." }, # INVENTED
        { category: :local_area, title: "Stari grad Visoki",
          content: "Ostaci srednjovjekovnog grada Visokog su na brdu iznad centra. Kratka šetnja i lijep " \
                   "pogled na dolinu Bosne." }, # INVENTED
        { category: :facilities, title: "Sala za sastanke (u pripremi)",
          content: "NACRT — ne objavljivati dok se ne potvrdi kapacitet i cjenovnik.",
          published: false, position: 99 }
      ],

      conversations: [
        { key: :bosnian,
          guest: { name: "Senad Hodžić", locale: "bs", room: "104", days_ago: 2 },
          status: :resolved, last_message_minutes_ago: 2_760, staff_unread_count: 0,
          messages: [
            { role: :guest, body: "Dobar dan, je li parking besplatan i ima li mjesta večeras?", minutes_ago: 2_766 },
            { role: :assistant, minutes_ago: 2_765,
              body: "Dobar dan! Da, parking ispred hotela je besplatan za sve naše goste. Mjesta obično " \
                    "ima — ako dolazite kasno navečer ili kombijem, mogu javiti recepciji da vam " \
                    "sačuvaju mjesto." },
            { role: :guest, body: "Dolazim oko 22h, obično auto.", minutes_ago: 2_762 },
            { role: :assistant, minutes_ago: 2_761,
              body: "U redu — nema potrebe za rezervacijom, ali sam javio recepciji da vas očekuju oko " \
                    "22:00. Vidimo se!" },
            { role: :guest, body: "Hvala puno.", minutes_ago: 2_760 }
          ] },

        { key: :english,
          guest: { name: "Elena Marchetti", locale: "en", room: "206", days_ago: 1 },
          last_message_minutes_ago: 980, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 986,
              body: "We're here for the pyramids. How far is the hotel from Sarajevo, and can we get a lift to the airport on Sunday?" },
            { role: :assistant, minutes_ago: 985,
              body: "Visoko is 32 km from Sarajevo, and the airport is about half an hour by car. We can " \
                    "arrange transport — tell me the time and how many of you there are and I'll send " \
                    "it to reception." },
            { role: :guest, body: "Sunday 10:00, two of us.", minutes_ago: 982 },
            { role: :assistant, minutes_ago: 980,
              body: "Sent to reception — transport on Sunday at 10:00 for two. It's pending until they " \
                    "confirm the driver." }
          ] },

        { key: :german,
          guest: { name: "Hannah Brunner", locale: "de", room: "109", days_ago: 1 },
          status: :escalated, escalation_reason: :ai_uncertain, escalated_minutes_ago: 290,
          last_message_minutes_ago: 170, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 295,
              body: "Ist das Zimmer 109 rollstuhlgerecht? Meine Mutter kommt nächste Woche und ich " \
                    "möchte sichergehen." },
            { role: :assistant, minutes_ago: 291,
              body: "Wir haben barrierefreie Zimmer und einen Aufzug zu allen Etagen — aber ob genau " \
                    "Zimmer 109 geeignet ist, kann ich nicht mit Sicherheit sagen. Ich habe die " \
                    "Rezeption informiert, sie meldet sich persönlich bei Ihnen." },
            { role: :system, minutes_ago: 290, visibility: :internal,
              body: "The assistant handed this over (ai uncertain): guest asking whether a specific room " \
                    "is wheelchair accessible. The knowledge base says accessible rooms exist but not " \
                    "which. Needs someone who knows the building." },
            { role: :staff, minutes_ago: 170, locale: "bs", user: :reception_0,
              body: "Guten Tag, Frau Brunner — Zimmer 109 ist nicht das barrierefreie. Wir haben Ihrer " \
                    "Mutter Zimmer 101 im Erdgeschoss reserviert, das ist besser geeignet." }
          ] },

        { key: :arabic,
          guest: { name: "ليلى بن صالح", locale: "ar", room: "203", days_ago: 1,
                   phone: "+38763221100", channel: :whatsapp },
          last_message_minutes_ago: 145, staff_unread_count: 1,
          messages: [
            { role: :guest, body: "مرحباً، هل يوجد طعام نباتي في المطعم؟ وهل المسبح مفتوح اليوم؟", minutes_ago: 150 },
            { role: :assistant, minutes_ago: 149,
              body: "أهلاً بك! نعم، المطعم يقدم أطباقاً نباتية إلى جانب المأكولات المحلية والعالمية " \
                    "والبيتزا. المسبح الداخلي متاح لنزلاء الفندق، ويمكنك أخذ مناشف المسبح من مركز " \
                    "الويلنس." },
            { role: :guest, body: "شكراً لك", minutes_ago: 145 }
          ] },

        { key: :waiting,
          guest: { name: "Adisa Ramić", locale: "bs", room: "111", days_ago: 0 },
          last_message_minutes_ago: 20, last_guest_message_minutes_ago: 20, staff_unread_count: 1,
          messages: [
            { role: :guest, minutes_ago: 20,
              body: "Možemo li dobiti salu za mali sastanak sutra ujutro, nas šestero?" }
          ] }
      ],

      requests: [
        { category: :taxi, conversation: :english, status: :accepted, minutes_ago: 980,
          summary: "Prevoz — aerodrom, nedjelja 10:00",
          details: { "time" => "10:00", "people" => "2", "description" => "prevoz do aerodroma" },
          acknowledged_minutes_ago: 960, acknowledged_by: :reception_1 },

        { category: :restaurant, conversation: :bosnian, status: :completed, minutes_ago: 2_600,
          summary: "Rezervacija stola — večera za dvoje, 20:00",
          details: { "time" => "20:00", "people" => "2", "description" => "sto uz prozor ako može" },
          acknowledged_minutes_ago: 2_580, acknowledged_by: :reception_0, completed_minutes_ago: 2_400 },

        { category: :spa_booking, conversation: :arabic, status: :in_progress, minutes_ago: 140,
          summary: "Wellness — bazen i sauna, popodne",
          details: { "time" => "17:00", "people" => "2", "description" => "bazen i sauna" },
          acknowledged_minutes_ago: 130, acknowledged_by: :reception_2 },

        { category: :towels, conversation: :bosnian, status: :new, minutes_ago: 25,
          summary: "Peškiri i posteljina — dodatni peškiri za bazen",
          details: { "quantity" => "2", "description" => "peškiri za bazen" } },

        { category: :late_checkout, conversation: :german, status: :declined, minutes_ago: 520,
          summary: "Kasna odjava — do 15:00",
          details: { "time" => "15:00", "description" => "hotel pun, soba potrebna za dolazak grupe" },
          acknowledged_minutes_ago: 510, acknowledged_by: :admin },

        { category: :room_service, conversation: :english, status: :cancelled, minutes_ago: 380,
          summary: "Posluga u sobu — večera",
          details: { "description" => "gost je ipak sišao u restoran", "time" => "21:00", "people" => "2" } },

        # Older than this hotel's 90-minute threshold and unclaimed.
        { category: :repair, conversation: :bosnian, status: :new, minutes_ago: 210,
          summary: "Kvar u sobi — slaba topla voda",
          details: { "description" => "u sobi 104 topla voda dolazi sporo, gost prijavio jutros" } }
      ],

      unanswered: [
        { question: "Which rooms are wheelchair accessible?",
          original: "Ist das Zimmer rollstuhlgerecht?", locale: "de", times: 3 },
        { question: "Do you have a meeting room for small groups?",
          original: "Imate li salu za mali sastanak?", locale: "bs", times: 4 },
        { question: "Can you organise a guided tour of the pyramids?", original: nil, locale: "en", times: 2 }
      ],

      usage_history_days: 10
    }
  end
end
