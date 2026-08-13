# Hotel Hills Sarajevo — Congress & Thermal Spa Resort, Ilidža.
#
# A real hotel, seeded as a pilot candidate. Facts marked SOURCED come from
# hotelhills.ba and are the hotel's own published information — correct them
# only against the source. Everything marked INVENTED is plausible filler
# written to make the demo complete: it is what a hotel of this kind would
# plausibly say, not what this hotel has said. Nothing invented here touches
# price, legal terms, or anything that would mislead a real guest about money.
#
# The character to preserve when editing: this is the big one. 330 rooms, a
# congress centre, thermal water, indoor and outdoor pools. Its guests are
# conference delegates and spa visitors, not backpackers.

module DemoCatalogue
  def self.hotel_hills
    {
      hotel: {
        name: "Hotel Hills Sarajevo",
        slug: "hotel-hills-sarajevo",
        timezone: "Europe/Sarajevo",
        staff_locale: "bs",
        # Deep green and warm gold — the resort's own palette reads green
        # against the Ilidža parkland.
        primary_color: "#1B5E4A",
        secondary_color: "#D4A537",
        concierge_name: "Lejla",
        welcome_message: "Dobrodošli u Hotel Hills! Pitajte me bilo šta — spa, kongres, doručak, transfer do aerodroma.",
        contact_phone: "+387 33 947 947", # SOURCED: hotelhills.ba
        checkout_time: "12:00",           # INVENTED — not published
        contact_notes: "Recepcija radi 24 sata. Za hitne slučajeve zovite 122 (policija) ili 124 (hitna pomoć).",
        overdue_after_minutes: 90
      },

      admin: { name: "Selma Karahodžić", email: "admin@hotel-hills.demo", locale: "bs" },
      reception: [
        { name: "Adnan Mujić", email: "adnan@hotel-hills.demo", locale: "bs" },
        { name: "Ivana Perić", email: "ivana@hotel-hills.demo", locale: "bs" },
        { name: "Haris Delić", email: "haris@hotel-hills.demo", locale: "en" }
      ],

      # A resort floor plan: a block on each of three floors, plus suites.
      room_numbers: (201..212).to_a + (305..316).to_a + (501..506).to_a,

      departments: {
        housekeeping: "Domaćinstvo",
        front_desk: "Recepcija",
        spa: "Wellness i spa",
        kitchen: "Restoran i posluga",
        congress: "Kongresni centar",
        maintenance: "Održavanje"
      },

      categories: {
        towels: { department: :housekeeping, key: "room_items", name: "Peškiri i posteljina",
                  detail_fields: %w[quantity description] },
        cleaning: { department: :housekeeping, key: "cleaning", name: "Čišćenje sobe",
                    detail_fields: %w[time description] },
        room_service: { department: :kitchen, key: "room_service", name: "Posluga u sobu",
                        detail_fields: %w[description time people] },
        spa_booking: { department: :spa, key: "spa_booking", name: "Termin u spa centru",
                       detail_fields: %w[time people description] },
        congress: { department: :congress, key: "congress_support", name: "Kongresna sala — podrška",
                    detail_fields: %w[time people description] },
        transfer: { department: :front_desk, key: "airport_transfer", name: "Transfer do aerodroma",
                    detail_fields: %w[time people description] },
        late_checkout: { department: :front_desk, key: "late_checkout", name: "Kasna odjava",
                         detail_fields: %w[time description] },
        repair: { department: :maintenance, key: "maintenance", name: "Kvar u sobi",
                  detail_fields: %w[description] }
      },

      knowledge: [
        # SOURCED: hotelhills.ba — buffet, Bosnian + international, halal and
        # vegetarian options. Hours are INVENTED; the hotel does not publish them.
        { category: :dining, title: "Doručak",
          content: "Doručak je švedski sto sa bosanskom i internacionalnom kuhinjom — uključujući halal i " \
                   "vegetarijanska jela, te američki doručak. Služi se od 06:30 do 10:30. Ako putujete " \
                   "ranije, javite recepciji večer prije i pripremimo vam doručak za ponijeti." },
        # SOURCED: panoramic rooftop restaurant and lounge bar; "Sky bar" for events.
        { category: :dining, title: "Panoramski restoran i Sky bar",
          content: "Na krovu hotela nalazi se panoramski restoran s pogledom na Sarajevsko polje i " \
                   "Igman, uz lounge bar. Sky bar se koristi i za organizovane događaje — za rezervaciju " \
                   "cijelog prostora pitajte recepciju." },
        { category: :dining, title: "Restorani u hotelu",
          content: "U hotelu su restorani s internacionalnom i domaćom kuhinjom. Za veće grupe i kongresne " \
                   "goste organizujemo poseban meni — najavite broj osoba dan ranije." }, # INVENTED
        { category: :dining, title: "Posluga u sobu",
          content: "Posluga u sobu dostupna je od 07:00 do 23:00. Meni je u fascikli u sobi, a narudžbu " \
                   "možete predati i ovdje u chatu." }, # INVENTED
        # SOURCED: wellness/spa/fitness centre, 10 treatment rooms, mud baths,
        # solarium, jacuzzi, sauna; indoor and outdoor pools; thermal water.
        { category: :facilities, title: "Spa i wellness centar",
          content: "Wellness, spa i fitness centar ima 10 tretmanskih soba, blatne kupke, saunu, jacuzzi " \
                   "i solarij. Termalna voda je ono po čemu je Ilidža poznata. Za masaže i tretmane " \
                   "preporučujemo raniju rezervaciju — mogu je dogovoriti odavde." },
        { category: :facilities, title: "Bazeni",
          content: "Hotel ima zatvoreni i otvoreni bazen. Zatvoreni radi tokom cijele godine, otvoreni " \
                   "ljeti. Peškire za bazen dobijate u wellness centru, ne treba nositi iz sobe." }, # hours INVENTED
        # SOURCED: multipurpose congress centre with modern conference technology.
        { category: :facilities, title: "Kongresni centar",
          content: "Kongresni centar je višenamjenski, sa modernom konferencijskom tehnikom, i prilagođava " \
                   "se od manjih sastanaka do velikih konferencija. Ako ste ovdje zbog skupa, recepcija " \
                   "ima raspored sala i može vas uputiti." },
        { category: :facilities, title: "Fitness",
          content: "Teretana je u sklopu wellness centra i besplatna je za goste hotela. Radi od 06:00 " \
                   "do 22:00." }, # INVENTED
        { category: :facilities, title: "Wi-Fi",
          content: "Besplatan Wi-Fi u sobama i u cijelom kongresnom dijelu. Mreža: HotelHills. Lozinku " \
                   "dobijate pri prijavi, a možete je pitati i ovdje." }, # INVENTED
        { category: :facilities, title: "Parking",
          content: "Parking za goste hotela je u krugu hotela. Ako dolazite s većom grupom ili autobusom, " \
                   "najavite se recepciji da vam osiguramo mjesto." }, # INVENTED — not published
        # SOURCED: every room has a private balcony, A/C, satellite TV, minibar.
        { category: :rooms, title: "Oprema sobe",
          content: "Sve sobe i apartmani imaju vlastiti balkon, klimu, satelitsku televiziju i mini bar. " \
                   "Sobe su prostrane i moderno opremljene." },
        # SOURCED: 330 rooms and suites.
        { category: :rooms, title: "Sobe i apartmani",
          content: "Hotel ima 330 soba i apartmana. Ako vam soba ne odgovara — sprat, pogled, tišina — " \
                   "javite recepciji i pokušat ćemo zamijeniti, ovisno o popunjenosti." },
        { category: :rooms, title: "Dodatni ležaj i krevetac",
          content: "Dodatni ležaj je moguć u većini soba uz najavu. Krevetac za bebe je besplatan — " \
                   "zatražite ga pri prijavi ili ovdje." }, # INVENTED
        { category: :rooms, title: "Sef u sobi",
          content: "Svaka soba ima sef. Ako ste zaboravili šifru, recepcija ga otvara uz provjeru " \
                   "dokumenta." }, # INVENTED
        { category: :policies, title: "Prijava i odjava",
          content: "Prijava je od 14:00, odjava do 12:00. Kasna odjava je moguća ovisno o popunjenosti — " \
                   "pitajte recepciju na dan odlaska, a mogu i ja provjeriti odavde." }, # INVENTED
        { category: :policies, title: "Pušenje",
          content: "Sobe su nepušačke. Pušenje je dozvoljeno na balkonima i na označenim mjestima " \
                   "ispred hotela." }, # INVENTED
        { category: :policies, title: "Kućni ljubimci",
          content: "Kućni ljubimci su dobrodošli uz prethodnu najavu. Javite nam veličinu i vrstu " \
                   "pri rezervaciji." }, # INVENTED
        # SOURCED: ~3.5 km from Sarajevo airport.
        { category: :transport, title: "Aerodrom",
          content: "Sarajevski aerodrom je oko 3,5 km od hotela — nekoliko minuta vožnje. Transfer možemo " \
                   "organizovati; recite mi vrijeme leta i broj osoba." },
        { category: :transport, title: "Do centra Sarajeva",
          content: "Do centra grada najlakše je tramvajem sa Ilidže — linija ide do Baščaršije i vožnja " \
                   "traje oko 30 minuta. Taksi je brži. Recepcija vam može pozvati taksi." }, # INVENTED
        # SOURCED: Butmirska cesta 18, Ilidža.
        { category: :local_area, title: "Gdje se nalazimo",
          content: "Hotel je na Butmirskoj cesti 18 na Ilidži, u zelenom dijelu Sarajeva. Vrelo Bosne i " \
                   "Velika aleja su u blizini — šetnja alejom je ono što gosti najčešće pohvale." },
        { category: :local_area, title: "Vrelo Bosne",
          content: "Vrelo Bosne je nadomak hotela. Do izvora se ide Velikom alejom, pješke ili fijakerom. " \
                   "Najljepše je ujutro, prije nego dođu grupe." }, # INVENTED
        { category: :local_area, title: "Tunel spasa",
          content: "Muzej Tunel spasa je blizu aerodroma, desetak minuta vožnje od hotela. Vrijedi ga " \
                   "vidjeti ako ste prvi put u Sarajevu." }, # INVENTED
        { category: :facilities, title: "Nova sala za sastanke (u pripremi)",
          content: "NACRT — ne objavljivati dok se ne potvrdi datum otvaranja.",
          published: false, position: 99 }
      ],

      conversations: [
        { key: :bosnian,
          guest: { name: "Amra Begić", locale: "bs", room: "207", days_ago: 2 },
          status: :resolved, last_message_minutes_ago: 2_870, staff_unread_count: 0,
          messages: [
            { role: :guest, body: "Dobar dan, do kada radi spa i treba li rezervacija za masažu?", minutes_ago: 2_875 },
            { role: :assistant, minutes_ago: 2_874,
              body: "Dobar dan! Wellness i spa centar ima 10 tretmanskih soba, saunu, jacuzzi i blatne " \
                    "kupke. Za masažu preporučujem raniju rezervaciju — mogu vam odmah dogovoriti termin, " \
                    "recite mi kada vam odgovara." },
            { role: :guest, body: "Sutra popodne oko 16h, za dvoje.", minutes_ago: 2_872 },
            { role: :assistant, minutes_ago: 2_871,
              body: "Poslao sam zahtjev wellness centru za sutra u 16:00, za dvije osobe. Javit će vam " \
                    "potvrdu — zahtjev je na čekanju dok ga ne potvrde." },
            { role: :guest, body: "Odlično, hvala!", minutes_ago: 2_870 }
          ] },

        { key: :english,
          guest: { name: "Thomas Reiner", locale: "en", room: "312", days_ago: 1 },
          last_message_minutes_ago: 1_180, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 1_185,
              body: "I'm here for the conference tomorrow. What time does breakfast start? I need to be in the hall by 8." },
            { role: :assistant, minutes_ago: 1_184,
              body: "Breakfast starts at 06:30, so you have plenty of time before 8. It's a buffet with " \
                    "Bosnian and international options, including halal and vegetarian. The congress " \
                    "centre is in the same building — reception has the room schedule." },
            { role: :guest, body: "Perfect. Could I also get a taxi to the airport on Thursday at 05:30?", minutes_ago: 1_182 },
            { role: :assistant, minutes_ago: 1_181,
              body: "Of course — a transfer to the airport on Thursday at 05:30, for one person. Shall I " \
                    "send that to reception?" },
            { role: :guest, body: "Yes please.", minutes_ago: 1_180 }
          ] },

        # The assistant hands over to a person — the question a sceptical
        # hotelier asks first.
        { key: :german,
          guest: { name: "Petra Neumann", locale: "de", room: "504", days_ago: 1 },
          status: :escalated, escalation_reason: :ai_uncertain, escalated_minutes_ago: 410,
          last_message_minutes_ago: 240, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 415,
              body: "Wir haben die Suite für eine Firmenfeier gebucht. Können wir eigenes Catering mitbringen?" },
            { role: :assistant, minutes_ago: 411,
              body: "Das kann ich Ihnen nicht mit Sicherheit sagen — dazu muss jemand aus dem Haus " \
                    "entscheiden. Ich habe die Rezeption informiert, sie meldet sich persönlich bei Ihnen." },
            { role: :system, minutes_ago: 410, visibility: :internal,
              body: "The assistant handed this over (ai uncertain): guest in suite 504 asks whether " \
                    "outside catering is allowed for a private event. Not in the knowledge base — needs " \
                    "a decision from F&B or the congress team." },
            { role: :staff, minutes_ago: 240, locale: "bs", user: :reception_1,
              body: "Guten Tag, Frau Neumann — wir klären das gerne mit Ihnen persönlich. Unser " \
                    "Bankett-Team ruft Sie in Kürze an." }
          ] },

        { key: :arabic,
          guest: { name: "نورة العتيبي", locale: "ar", room: "310", days_ago: 1,
                   phone: "+38762334455", channel: :whatsapp },
          last_message_minutes_ago: 190, staff_unread_count: 1,
          messages: [
            { role: :guest, body: "السلام عليكم، هل الإفطار حلال؟ وهل يوجد مسبح للنساء؟", minutes_ago: 195 },
            { role: :assistant, minutes_ago: 194,
              body: "وعليكم السلام! نعم، الإفطار يشمل خيارات حلال، إضافة إلى أطباق بوسنية وعالمية " \
                    "ونباتية. لدى الفندق مسبح داخلي ومسبح خارجي — لمعرفة أوقات مخصصة للسيدات في مركز " \
                    "السبا، يمكنني سؤال الاستقبال نيابة عنك." },
            { role: :guest, body: "نعم من فضلك", minutes_ago: 190 }
          ] },

        { key: :waiting,
          guest: { name: "Damir Šehić", locale: "bs", room: "205", days_ago: 0 },
          last_message_minutes_ago: 8, last_guest_message_minutes_ago: 8, staff_unread_count: 1,
          messages: [
            { role: :guest, minutes_ago: 8,
              body: "Trebam fakturu na firmu za boravak i kongresnu kotizaciju. Kome da pošaljem podatke?" }
          ] }
      ],

      requests: [
        { category: :spa_booking, conversation: :bosnian, status: :accepted, minutes_ago: 2_871,
          summary: "Termin u spa centru — masaža za dvoje, 16:00",
          details: { "time" => "16:00", "people" => "2", "description" => "masaža, sutra popodne" },
          acknowledged_minutes_ago: 2_850, acknowledged_by: :reception_1 },

        { category: :transfer, conversation: :english, status: :new, minutes_ago: 30,
          summary: "Transfer do aerodroma — četvrtak, 05:30",
          details: { "time" => "05:30", "people" => "1", "description" => "let u 07:40" } },

        { category: :room_service, conversation: :english, status: :in_progress, minutes_ago: 150,
          summary: "Posluga u sobu — kasna večera za jednog",
          details: { "description" => "sendvič i čaj", "time" => "22:30", "people" => "1" },
          acknowledged_minutes_ago: 140, acknowledged_by: :reception_0 },

        { category: :towels, conversation: :arabic, status: :completed, minutes_ago: 900,
          summary: "Peškiri i posteljina — 2 dodatna peškira",
          details: { "quantity" => "2", "description" => "peškiri za bazen" },
          acknowledged_minutes_ago: 890, acknowledged_by: :reception_2, completed_minutes_ago: 860 },

        { category: :congress, conversation: :german, status: :declined, minutes_ago: 700,
          summary: "Kongresna sala — vlastiti catering za privatnu proslavu",
          details: { "people" => "40", "time" => "19:00", "description" => "vanjski catering u sali" },
          acknowledged_minutes_ago: 690, acknowledged_by: :admin },

        { category: :late_checkout, conversation: :german, status: :cancelled, minutes_ago: 500,
          summary: "Kasna odjava — do 15:00",
          details: { "time" => "15:00", "description" => "gost je promijenio let" } },

        # Older than this hotel's own 90-minute threshold and unclaimed, so the
        # board opens with a genuinely overdue card.
        { category: :repair, conversation: :bosnian, status: :new, minutes_ago: 260,
          summary: "Kvar u sobi — ne radi klima na balkonskoj strani",
          details: { "description" => "klima u sobi 207 ne hladi, gost prijavio jutros" } }
      ],

      unanswered: [
        { question: "Is outside catering allowed in the congress hall?",
          original: "Können wir eigenes Catering mitbringen?", locale: "de", times: 3 },
        { question: "Are there women-only hours at the spa?",
          original: "هل يوجد وقت مخصص للنساء في السبا؟", locale: "ar", times: 5 },
        { question: "Is there a shuttle bus to the old town?", original: nil, locale: "en", times: 2 }
      ],

      # Shorter than Stari Grad's 21 days: five hotels' worth of AiRun rows are
      # created on every test that loads this seed, and each fires a rollup
      # callback. Ten days still fills the analytics charts with a shape.
      usage_history_days: 10
    }
  end
end
