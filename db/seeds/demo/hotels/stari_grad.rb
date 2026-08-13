# Hotel Stari Grad Sarajevo — the fictional demo hotel.
#
# Unlike the other four in this directory, no such hotel exists. That is the
# point: it is the one that can be shown to any audience without a real
# business's name and half-invented facts being on screen. Everything here is
# invented, so nothing is marked SOURCED.

module DemoCatalogue
  def self.stari_grad
    {
      hotel: {
        name: "Hotel Stari Grad Sarajevo",
        slug: "stari-grad-sarajevo",
        timezone: "Europe/Sarajevo",
        staff_locale: "bs",
        primary_color: "#1F3A5F",
        secondary_color: "#C9A227",
        concierge_name: "Amina",
        welcome_message: "Dobrodošli! Pitajte me bilo šta o hotelu i Sarajevu — odgovaram na vašem jeziku.",
        contact_phone: "+387 33 000 000",
        checkout_time: "11:00",
        contact_notes: "Recepcija je otvorena 24 sata. Za hitne slučajeve zovite 122 (policija) ili 124 (hitna pomoć).",
        overdue_after_minutes: 60
      },

      admin: { name: "Mirza Sehović", email: "admin@stari-grad.demo", locale: "bs" },
      reception: [
        { name: "Amira Hodžić", email: "amira@stari-grad.demo", locale: "bs" },
        { name: "Dino Bešić", email: "dino@stari-grad.demo", locale: "bs" },
        { name: "Lejla Kovač", email: "lejla@stari-grad.demo", locale: "en" }
      ],

      room_numbers: (301..310).to_a + (401..408).to_a,

      departments: {
        housekeeping: "Domaćinstvo",
        front_desk: "Recepcija",
        kitchen: "Kuhinja",
        maintenance: "Održavanje"
      },

      categories: {
        towels: { department: :housekeeping, key: "room_items", name: "Peškiri i posteljina",
                  detail_fields: %w[quantity description] },
        cleaning: { department: :housekeeping, key: "cleaning", name: "Čišćenje sobe",
                    detail_fields: %w[time description] },
        breakfast: { department: :kitchen, key: "room_service", name: "Posluga u sobu",
                     detail_fields: %w[description time people] },
        taxi: { department: :front_desk, key: "taxi", name: "Taksi",
                detail_fields: %w[time people description] },
        late_checkout: { department: :front_desk, key: "late_checkout", name: "Kasna odjava",
                         detail_fields: %w[time description] },
        repair: { department: :maintenance, key: "maintenance", name: "Kvar u sobi",
                  detail_fields: %w[description] }
      },

      knowledge: [
        { category: :dining, title: "Doručak",
          content: "Doručak se služi u restoranu na prvom spratu od 07:00 do 10:30, vikendom do 11:00. " \
                   "Uključen je u cijenu sobe. Ako ranije putujete, javite nam večer prije i spakovaćemo vam " \
                   "doručak za ponijeti." },
        { category: :dining, title: "Restoran i večera",
          content: "Naš restoran radi od 18:00 do 23:00. Nudimo bosansku kuhinju — begova čorba, japrak, " \
                   "ćevapi — i vegetarijanska jela. Rezervacija nije obavezna, ali je preporučujemo vikendom." },
        { category: :dining, title: "Posluga u sobu",
          content: "Posluga u sobu dostupna je od 07:00 do 22:00. Meni se nalazi u fascikli na stolu u sobi." },
        { category: :dining, title: "Kafa i piće",
          content: "Lobi bar radi do ponoći. Bosanska kafa se služi na tradicionalan način, u džezvi." },
        { category: :policies, title: "Odjava",
          content: "Odjava je do 11:00. Kasna odjava do 14:00 moguća je uz doplatu od 20 KM, ovisno o " \
                   "popunjenosti — pitajte recepciju na dan odlaska." },
        { category: :policies, title: "Prijava",
          content: "Prijava je od 14:00. Ako stižete ranije, čuvamo vaš prtljag besplatno na recepciji." },
        { category: :policies, title: "Pušenje",
          content: "Hotel je nepušački. Pušenje je dozvoljeno na terasi u dvorištu. Kazna za pušenje u sobi " \
                   "je 100 KM." },
        { category: :policies, title: "Kućni ljubimci",
          content: "Mali kućni ljubimci do 10 kg su dobrodošli uz najavu i doplatu od 15 KM po noći." },
        { category: :policies, title: "Otkazivanje",
          content: "Besplatno otkazivanje do 48 sati prije dolaska. Nakon toga se naplaćuje prva noć." },
        { category: :facilities, title: "Wi-Fi",
          content: "Besplatan Wi-Fi u cijelom hotelu. Mreža: StariGradGuest. Lozinka je na kartici u sobi i " \
                   "mijenja se sedmično." },
        { category: :facilities, title: "Parking",
          content: "Hotel ima 12 parking mjesta u dvorištu, 10 KM po noći, po dolasku. Stari Grad je pješačka " \
                   "zona pa preporučujemo da rezervišete mjesto pri rezervaciji sobe." },
        { category: :facilities, title: "Klima i grijanje",
          content: "Sve sobe imaju klimu i grijanje sa zasebnom kontrolom. Ako nešto ne radi, javite " \
                   "recepciji — održavanje dolazi isti dan." },
        { category: :facilities, title: "Praonica",
          content: "Usluga pranja i peglanja: predajte na recepciji do 09:00, vraćamo isti dan do 18:00." },
        { category: :facilities, title: "Bazen i spa",
          content: "Hotel nema bazen. Najbliži su termalni bazeni na Ilidži, oko 20 minuta tramvajem broj 3." },
        { category: :rooms, title: "Sef u sobi",
          content: "Svaka soba ima sef u ormaru. Ako ste zaboravili šifru, recepcija ga može otvoriti uz " \
                   "provjeru dokumenta." },
        { category: :rooms, title: "Dodatni ležaj",
          content: "Dodatni ležaj je moguć u sobama 301–305, uz doplatu od 30 KM po noći." },
        { category: :local_area, title: "Baščaršija",
          content: "Baščaršija je 4 minute hoda od hotela. Sebilj, Gazi Husrev-begova džamija i kazandžijski " \
                   "sokak su svi u krugu od 200 metara." },
        { category: :local_area, title: "Šta vidjeti",
          content: "U pješačkoj udaljenosti: Vijećnica (7 min), Latinska ćuprija (6 min), Tunel spasa je " \
                   "20 minuta taksijem. Vidikovac Žuta tabija je 15 minuta uzbrdo — najljepše je pred zalazak." },
        { category: :local_area, title: "Preporuke za jelo",
          content: "Za ćevape: Željo ili Petica, oba na Baščaršiji. Za baklavu: Badem. Za kafu s pogledom: " \
                   "Kafana Zlatna Ribica. Nemamo dogovor ni sa jednim od njih — to su mjesta gdje mi jedemo." },
        { category: :transport, title: "Aerodrom",
          content: "Aerodrom je 12 km, oko 20 minuta taksijem (25–30 KM). Možemo naručiti taksi — javite " \
                   "recepciji ili pitajte mene ovdje." },
        { category: :transport, title: "Tramvaj",
          content: "Najbliža tramvajska stanica je Baščaršija, 5 minuta hoda. Karta se kupi na kiosku (1,80 KM) " \
                   "ili kod vozača (2 KM) i mora se poništiti u vozilu." },
        # A draft, so the published/unpublished distinction is visible on the
        # knowledge-base screen rather than only in the schema.
        { category: :facilities, title: "Krovna terasa (u pripremi)",
          content: "NACRT — ne objavljivati dok se ne potvrdi datum otvaranja.",
          published: false, position: 99 }
      ],

      conversations: [
        # 1. Bosnian — a grounded answer, the ordinary case.
        { key: :bosnian,
          guest: { name: "Emina Softić", locale: "bs", room: "302", days_ago: 2 },
          status: :resolved, last_message_minutes_ago: 2_878, staff_unread_count: 0,
          messages: [
            { role: :guest, body: "Dobar dan! Do kada je doručak?", minutes_ago: 2_880 },
            { role: :assistant, minutes_ago: 2_879,
              body: "Dobar dan! Doručak se služi od 07:00 do 10:30, a vikendom do 11:00 — uključen je u " \
                    "cijenu sobe. Ako ranije putujete, spakujemo vam doručak za ponijeti." },
            { role: :guest, body: "Super, hvala!", minutes_ago: 2_878 }
          ] },

        # 2. English — a request, gathered and confirmed, ending on the board.
        { key: :english,
          guest: { name: "James Whitfield", locale: "en", room: "305", days_ago: 1 },
          last_message_minutes_ago: 1_397, staff_unread_count: 0,
          messages: [
            { role: :guest, body: "Could I get two extra bath towels please?", minutes_ago: 1_400 },
            { role: :assistant, minutes_ago: 1_399,
              body: "Of course — two bath towels for room 305. Shall I send that to reception?" },
            { role: :guest, body: "Yes please", minutes_ago: 1_398 },
            { role: :assistant, minutes_ago: 1_397,
              body: "Sent to reception — it's pending and someone will bring them up." }
          ] },

        # 3. German — the assistant hands over to a person. A demo that only
        #    shows the happy path invites exactly the question it does not answer.
        { key: :german,
          guest: { name: "Klara Bergmann", locale: "de", room: "401", days_ago: 1 },
          status: :escalated, escalation_reason: :ai_uncertain, escalated_minutes_ago: 299,
          last_message_minutes_ago: 120, staff_unread_count: 0,
          messages: [
            { role: :guest, minutes_ago: 300,
              body: "Die Klimaanlage in meinem Zimmer macht ein lautes Geräusch, die ganze Nacht schon." },
            { role: :assistant, minutes_ago: 299,
              body: "Das tut mir leid — damit sollte sich jemand direkt ansehen. Ich habe die Rezeption " \
                    "informiert, sie meldet sich persönlich bei Ihnen." },
            { role: :system, minutes_ago: 299, visibility: :internal,
              body: "The assistant handed this over (ai uncertain): Guest reports a loud air conditioning " \
                    "unit in room 401, overnight. Needs maintenance." },
            { role: :staff, minutes_ago: 120, locale: "bs", user: :reception_0,
              body: "Guten Morgen, Frau Bergmann — unser Techniker kommt in 20 Minuten vorbei." }
          ] },

        # 4. Arabic — the RTL check, and on WhatsApp so the channel badge appears.
        { key: :arabic,
          guest: { name: "سامي المنصوري", locale: "ar", room: "403", days_ago: 1,
                   phone: "+38761555777", channel: :whatsapp },
          last_message_minutes_ago: 238, staff_unread_count: 1,
          messages: [
            { role: :guest, body: "مرحباً، هل يوجد مطعم حلال قريب من الفندق؟", minutes_ago: 240 },
            { role: :assistant, minutes_ago: 239,
              body: "أهلاً بك! نعم — معظم المطاعم في باشتشارشيا تقدم طعاماً حلالاً، وهي على بعد 4 دقائق " \
                    "سيراً على الأقدام. نوصي بمطعم Željo أو Petica للتشيفابي." },
            { role: :guest, body: "شكراً جزيلاً", minutes_ago: 238 }
          ] },

        # 5. A guest still waiting — so the inbox has something needing attention
        #    when the demo opens it.
        { key: :waiting,
          guest: { name: "Nikola Jovanović", locale: "bs", room: "306", days_ago: 0 },
          last_message_minutes_ago: 12, last_guest_message_minutes_ago: 12, staff_unread_count: 1,
          messages: [
            { role: :guest, minutes_ago: 12,
              body: "Mogu li dobiti račun na firmu? Trebaju mi podaci za fakturu." }
          ] }
      ],

      requests: [
        { category: :towels, conversation: :english, status: :new, minutes_ago: 20,
          summary: "Peškiri i posteljina — 2 peškira za kupanje",
          details: { "quantity" => "2", "description" => "peškiri za kupanje" } },

        { category: :breakfast, conversation: :english, status: :accepted, minutes_ago: 90,
          summary: "Posluga u sobu — doručak u 08:00",
          details: { "description" => "doručak za dvoje", "time" => "08:00", "people" => "2" },
          acknowledged_minutes_ago: 75, acknowledged_by: :reception_0 },

        { category: :cleaning, conversation: :arabic, status: :in_progress, minutes_ago: 200,
          summary: "Čišćenje sobe — poslije 14:00",
          details: { "time" => "14:00", "description" => "soba 403" },
          acknowledged_minutes_ago: 180, acknowledged_by: :reception_1 },

        { category: :taxi, conversation: :english, status: :completed, minutes_ago: 1_400,
          summary: "Taksi — aerodrom, 05:30",
          details: { "time" => "05:30", "people" => "1", "description" => "za aerodrom" },
          acknowledged_minutes_ago: 1_390, acknowledged_by: :reception_0, completed_minutes_ago: 1_300 },

        { category: :late_checkout, conversation: :german, status: :declined, minutes_ago: 800,
          summary: "Kasna odjava — do 16:00",
          details: { "time" => "16:00", "description" => "let u 19:00" },
          acknowledged_minutes_ago: 790, acknowledged_by: :admin },

        # A guest changed their mind — the ordinary way a request is cancelled,
        # and the last status needed for the board to show all six.
        { category: :taxi, conversation: :german, status: :cancelled, minutes_ago: 600,
          summary: "Taksi — u grad, 19:00",
          details: { "time" => "19:00", "people" => "2", "description" => "do Vijećnice" } },

        # Older than this hotel's own 60-minute threshold and still nobody's — so
        # the board opens with a genuinely overdue card rather than a tidy one.
        { category: :repair, conversation: :german, status: :new, minutes_ago: 240,
          summary: "Kvar u sobi — klima pravi buku",
          details: { "description" => "klima u sobi 401 pravi glasnu buku cijelu noć" } }
      ],

      unanswered: [
        { question: "Is there a swimming pool at the hotel?", original: "Ima li hotel bazen?",
          locale: "bs", times: 4 },
        { question: "Do you have a shuttle to the airport?", original: "Habt ihr einen Flughafen-Shuttle?",
          locale: "de", times: 2 },
        { question: "Can I store luggage after checkout?", original: nil, locale: "en", times: 1 }
      ],

      usage_history_days: 21
    }
  end
end
