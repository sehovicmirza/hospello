# Hotel Hollywood Sarajevo — Ilidža, beside the airport.
#
# A real hotel, seeded as a pilot candidate. Facts marked SOURCED come from
# hotel-hollywood.ba. Everything marked INVENTED is plausible filler written to
# make the demo complete — what a hotel of this kind would plausibly say, not
# what this hotel has said. Nothing invented touches price or legal terms.
#
# The character to preserve: the biggest of the four by room count, and the one
# with the most to do indoors — hammam, bowling, a sports hall, a salt room.
# Its guests are families, groups and people with an early flight.

module DemoCatalogue
  def self.hotel_hollywood
    {
      hotel: {
        name: "Hotel Hollywood Sarajevo",
        slug: "hotel-hollywood-sarajevo",
        timezone: "Europe/Sarajevo",
        staff_locale: "bs",
        primary_color: "#8C1D2F",
        secondary_color: "#E0B44A",
        concierge_name: "Nedim",
        welcome_message: "Dobrodošli u Hotel Hollywood! Pitajte me šta god treba — wellness, bowling, doručak, aerodrom.",
        contact_phone: "+387 33 773 100", # SOURCED: hotel-hollywood.ba
        checkout_time: "11:30",           # SOURCED: check-out do 11:30
        contact_notes: "Recepcija radi 24 sata. Za hitne slučajeve zovite 122 (policija) ili 124 (hitna pomoć).",
        overdue_after_minutes: 120
      },

      admin: { name: "Emir Hadžiabdić", email: "admin@hollywood.demo", locale: "bs" },
      reception: [
        { name: "Belma Softić", email: "belma@hollywood.demo", locale: "bs" },
        { name: "Vedran Marić", email: "vedran@hollywood.demo", locale: "bs" },
        { name: "Amina Zukić", email: "amina@hollywood.demo", locale: "en" }
      ],

      room_numbers: (110..123).to_a + (240..251).to_a + (360..367).to_a,

      departments: {
        housekeeping: "Domaćinstvo",
        front_desk: "Recepcija",
        wellness: "Wellness",
        kitchen: "Restoran Sokak",
        sports: "Sport i rekreacija",
        maintenance: "Održavanje"
      },

      categories: {
        towels: { department: :housekeeping, key: "room_items", name: "Peškiri i posteljina",
                  detail_fields: %w[quantity description] },
        cleaning: { department: :housekeeping, key: "cleaning", name: "Čišćenje sobe",
                    detail_fields: %w[time description] },
        room_service: { department: :kitchen, key: "room_service", name: "Posluga u sobu",
                        detail_fields: %w[description time people] },
        wellness_booking: { department: :wellness, key: "wellness_booking", name: "Wellness — termin",
                            detail_fields: %w[time people description] },
        bowling: { department: :sports, key: "bowling", name: "Kuglana — rezervacija staze",
                   detail_fields: %w[time people description] },
        taxi: { department: :front_desk, key: "taxi", name: "Taksi",
                detail_fields: %w[time people description] },
        late_checkout: { department: :front_desk, key: "late_checkout", name: "Kasna odjava",
                         detail_fields: %w[time description] },
        repair: { department: :maintenance, key: "maintenance", name: "Kvar u sobi",
                  detail_fields: %w[description] }
      },

      knowledge: [
        # SOURCED: Restaurant Sokak; three restaurants (local, international, Mediterranean).
        { category: :dining, title: "Restoran Sokak",
          content: "Restoran Sokak je naš glavni restoran, sa domaćom kuhinjom. U hotelu su ukupno tri " \
                   "restorana — domaća, internacionalna i mediteranska kuhinja." },
        { category: :dining, title: "Doručak",
          content: "Doručak je švedski sto i služi se od 06:30 do 10:30. Ako imate rani let, javite " \
                   "recepciji večer prije i spakujemo vam doručak za ponijeti — aerodrom je nekoliko " \
                   "minuta odavde." }, # INVENTED — hours not published
        { category: :dining, title: "Posluga u sobu",
          content: "Posluga u sobu radi od 07:00 do 23:00. Meni je u sobi, a narudžbu možete predati " \
                   "i ovdje." }, # INVENTED
        # SOURCED: indoor pool, Finnish/bio/infrared/steam saunas, Turkish
        # hammam, solarium, massage room, salt room, relax room, manicure /
        # pedicure, hairdresser.
        { category: :facilities, title: "Wellness centar",
          content: "Wellness centar ima zatvoreni bazen, finsku, bio, infracrvenu i parnu saunu, turski " \
                   "hamam, solarij, salu za masažu, slanu sobu i relax sobu. Tu su i manikir/pedikir i " \
                   "frizerski salon. Za masažu i tretmane preporučujemo rezervaciju." },
        { category: :facilities, title: "Turski hamam",
          content: "Hamam je dio wellness centra. Ako ga niste probali, recepcija ili osoblje wellnessa " \
                   "objasnit će vam kako teče — nije komplikovano i vrijedi ga probati." }, # INVENTED framing
        # SOURCED: sports hall, bowling alley, billiards.
        { category: :facilities, title: "Kuglana i bilijar",
          content: "Hotel ima kuglanu i bilijar, te sportsku salu. Staze u kuglani se rezervišu — recite " \
                   "mi termin i broj osoba pa ću poslati zahtjev." },
        { category: :facilities, title: "Sportska sala",
          content: "Sportska sala je u sklopu hotela i koristi se za rekreaciju i grupe. Termine " \
                   "dogovara recepcija." }, # INVENTED
        { category: :facilities, title: "Wi-Fi",
          content: "Bežični internet je dostupan u sobama i u konferencijskom dijelu hotela. Lozinku " \
                   "dobijate pri prijavi." }, # SOURCED that wifi exists; password handling INVENTED
        { category: :facilities, title: "Parking",
          content: "Parking je uz hotel. Ako dolazite autobusom ili s grupom, najavite se recepciji " \
                   "unaprijed." }, # INVENTED — not published
        # SOURCED: 466 units, four- and five-star superior/deluxe; king beds,
        # SAT + local TV, minibar, safe, A/C.
        { category: :rooms, title: "Sobe i apartmani",
          content: "Hotel ima 466 smještajnih jedinica, kategorije superior i deluxe. Sobe su prostrane, " \
                   "sa francuskim ležajem, satelitskom i lokalnom televizijom, telefonom, mini barom, " \
                   "sefom i klimom." },
        { category: :rooms, title: "Klima i grijanje",
          content: "Sve sobe imaju klimu. Ako nešto ne radi kako treba, javite — održavanje izlazi " \
                   "isti dan." }, # INVENTED
        { category: :rooms, title: "Dodatni ležaj",
          content: "Dodatni ležaj je moguć u većini soba uz najavu. Krevetac za bebe je besplatan." }, # INVENTED
        # SOURCED: check-in 15:00, check-out 11:30.
        { category: :policies, title: "Prijava i odjava",
          content: "Prijava je od 15:00, a odjava do 11:30. Ako stižete ranije ili odlazite kasnije, " \
                   "prtljag možemo čuvati na recepciji." },
        # SOURCED: cancellation 24 h individuals, 21 days groups.
        { category: :policies, title: "Otkazivanje rezervacije",
          content: "Za individualne goste rezervacija se može otkazati do 24 sata prije dolaska. Za " \
                   "grupe je rok 21 dan prije dolaska." },
        { category: :policies, title: "Pušenje",
          content: "Sobe su nepušačke. Pušenje je dozvoljeno na za to označenim mjestima." }, # INVENTED
        { category: :policies, title: "Kućni ljubimci",
          content: "Kućni ljubimci su mogući uz prethodnu najavu — javite nam vrstu i veličinu." }, # INVENTED
        # SOURCED: next to Sarajevo International Airport.
        { category: :transport, title: "Aerodrom",
          content: "Hotel je odmah uz Međunarodni aerodrom Sarajevo — nekoliko minuta vožnje. Ako imate " \
                   "rani let, mogu vam dogovoriti taksi za tačno vrijeme." },
        { category: :transport, title: "Do centra grada",
          content: "Do Baščaršije se ide tramvajem sa Ilidže, oko 30 minuta, ili taksijem, znatno brže. " \
                   "Recepcija vam može pozvati taksi." }, # INVENTED
        # SOURCED: Dr. Mustafe Pintola 23, Ilidža.
        { category: :local_area, title: "Gdje se nalazimo",
          content: "Adresa je Dr. Mustafe Pintola 23, Ilidža. To je zeleni dio Sarajeva, blizu aerodroma " \
                   "i glavnog saobraćajnog terminala." },
        { category: :local_area, title: "Vrelo Bosne i Velika aleja",
          content: "Vrelo Bosne je nadomak hotela. Velikom alejom se ide pješke ili fijakerom — " \
                   "popularna šetnja, posebno ljeti." }, # INVENTED
        { category: :local_area, title: "Za djecu",
          content: "Uz kuglanu i bazen, u blizini je i Vrelo Bosne za šetnju. Ako putujete s djecom, " \
                   "pitajte recepciju šta je trenutno otvoreno." }, # INVENTED
        { category: :facilities, title: "Nova teretana (u pripremi)",
          content: "NACRT — ne objavljivati dok se ne potvrdi datum otvaranja.",
          published: false, position: 99 }
      ],

      conversations: [
        { key: :bosnian,
          guest: { name: "Jasmin Karić", locale: "bs", room: "115", days_ago: 2 },
          status: :resolved, last_message_minutes_ago: 2_800, staff_unread_count: 0,
          messages: [
            { role: :guest, body: "Pozdrav, radi li kuglana večeras i može li se rezervisati staza?", minutes_ago: 2_806 },
            { role: :assistant, minutes_ago: 2_805,
              body: "Pozdrav! Da, hotel ima kuglanu. Staze se rezervišu — recite mi termin i koliko vas " \
                    "je, pa ću poslati zahtjev recepciji." },
            { role: :guest, body: "Oko 20h, četvero nas je.", minutes_ago: 2_803 },
            { role: :assistant, minutes_ago: 2_802,
              body: "Poslao sam zahtjev: kuglana večeras u 20:00, za četiri osobe. Na čekanju je dok ga " \
                    "recepcija ne potvrdi." },
            { role: :guest, body: "Hvala!", minutes_ago: 2_800 }
          ] },

        { key: :english,
          guest: { name: "Sarah Whitcombe", locale: "en", room: "244", days_ago: 1 },
          last_message_minutes_ago: 1_020, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 1_026,
              body: "My flight is at 06:15 tomorrow. Is there any way to get breakfast before I go?" },
            { role: :assistant, minutes_ago: 1_025,
              body: "Breakfast starts at 06:30, which is too late for a 06:15 flight — but we can pack " \
                    "one for you to take. The airport is only a few minutes away. Shall I arrange the " \
                    "packed breakfast and a taxi?" },
            { role: :guest, body: "Yes to both, taxi at 04:45 please.", minutes_ago: 1_022 },
            { role: :assistant, minutes_ago: 1_020,
              body: "Both sent to reception — pending until they confirm. Someone will leave the packed " \
                    "breakfast at the desk for you." }
          ] },

        { key: :german,
          guest: { name: "Markus Vogt", locale: "de", room: "362", days_ago: 1 },
          status: :escalated, escalation_reason: :ai_uncertain, escalated_minutes_ago: 330,
          last_message_minutes_ago: 200, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 335,
              body: "Wir sind eine Gruppe von 18 Personen und müssten die Anzahlung anders aufteilen. " \
                    "An wen kann ich mich wenden?" },
            { role: :assistant, minutes_ago: 331,
              body: "Das betrifft die Zahlung, und darüber darf ich nicht entscheiden — dafür ist unser " \
                    "Team zuständig. Ich habe die Rezeption informiert, sie meldet sich persönlich bei Ihnen." },
            { role: :system, minutes_ago: 330, visibility: :internal,
              body: "The assistant handed this over (guest requested): group of 18 asking to split a " \
                    "deposit. Payment question — never answered by the assistant." },
            { role: :staff, minutes_ago: 200, locale: "bs", user: :reception_0,
              body: "Guten Tag, Herr Vogt — unsere Kollegin aus dem Verkauf meldet sich heute bei Ihnen " \
                    "und klärt die Aufteilung mit Ihnen persönlich." }
          ] },

        { key: :arabic,
          guest: { name: "خالد الشمري", locale: "ar", room: "247", days_ago: 1,
                   phone: "+38761998877", channel: :whatsapp },
          last_message_minutes_ago: 160, staff_unread_count: 1,
          messages: [
            { role: :guest, body: "مساء الخير، ما هي أوقات الحمام التركي؟ وهل يمكن حجز مساج للرجال؟", minutes_ago: 166 },
            { role: :assistant, minutes_ago: 165,
              body: "مساء النور! الحمام التركي جزء من مركز الويلنس، ويضم أيضاً مسبحاً داخلياً وساونا " \
                    "فنلندية وبخارية وغرفة ملح. المساج يُحجز مسبقاً — أخبرني بالوقت المناسب وسأرسل الطلب." },
            { role: :guest, body: "غداً الساعة السابعة مساءً", minutes_ago: 160 }
          ] },

        { key: :waiting,
          guest: { name: "Merima Delić", locale: "bs", room: "118", days_ago: 0 },
          last_message_minutes_ago: 15, last_guest_message_minutes_ago: 15, staff_unread_count: 1,
          messages: [
            { role: :guest, minutes_ago: 15,
              body: "Zaboravila sam punjač u sobi prošli put kad smo bili. Ima li šanse da je kod vas?" }
          ] }
      ],

      requests: [
        { category: :bowling, conversation: :bosnian, status: :completed, minutes_ago: 2_802,
          summary: "Kuglana — staza u 20:00, četiri osobe",
          details: { "time" => "20:00", "people" => "4", "description" => "jedna staza" },
          acknowledged_minutes_ago: 2_790, acknowledged_by: :reception_1, completed_minutes_ago: 2_600 },

        { category: :taxi, conversation: :english, status: :accepted, minutes_ago: 1_020,
          summary: "Taksi — aerodrom, 04:45",
          details: { "time" => "04:45", "people" => "1", "description" => "let u 06:15" },
          acknowledged_minutes_ago: 1_000, acknowledged_by: :reception_0 },

        { category: :room_service, conversation: :english, status: :new, minutes_ago: 40,
          summary: "Posluga u sobu — doručak za ponijeti",
          details: { "description" => "spakovati doručak, gost ima rani let", "time" => "04:30", "people" => "1" } },

        { category: :wellness_booking, conversation: :arabic, status: :in_progress, minutes_ago: 158,
          summary: "Wellness — masaža, sutra u 19:00",
          details: { "time" => "19:00", "people" => "1", "description" => "masaža za muškarce" },
          acknowledged_minutes_ago: 150, acknowledged_by: :reception_2 },

        { category: :late_checkout, conversation: :german, status: :declined, minutes_ago: 600,
          summary: "Kasna odjava — grupa, do 16:00",
          details: { "time" => "16:00", "description" => "grupa od 18 osoba, hotel pun" },
          acknowledged_minutes_ago: 590, acknowledged_by: :admin },

        { category: :cleaning, conversation: :bosnian, status: :cancelled, minutes_ago: 420,
          summary: "Čišćenje sobe — poslije 15:00",
          details: { "time" => "15:00", "description" => "gost otkazao, ostaje u sobi" } },

        # Older than this hotel's 120-minute threshold and unclaimed.
        { category: :repair, conversation: :german, status: :new, minutes_ago: 300,
          summary: "Kvar u sobi — ne zaključava se sef",
          details: { "description" => "sef u sobi 362 se ne zaključava, gost prijavio popodne" } }
      ],

      unanswered: [
        { question: "Can a group deposit be split across several cards?",
          original: "Können wir die Anzahlung aufteilen?", locale: "de", times: 4 },
        { question: "What are the Turkish hammam opening hours?",
          original: "ما هي أوقات الحمام التركي؟", locale: "ar", times: 3 },
        { question: "Is the bowling alley open on Sundays?", original: nil, locale: "en", times: 2 }
      ],

      usage_history_days: 10
    }
  end
end
