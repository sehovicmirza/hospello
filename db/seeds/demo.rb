# Demo data: a realistic, fully configured Sarajevo hotel that can be presented
# to a hotel decision-maker without entering anything by hand.
#
# Loaded only when SEED_DEMO=1 (see db/seeds.rb). **Someone will eventually run
# this against production**, so it is built to make that safe rather than
# unlikely: it refuses outright if the database already holds a hotel it did not
# create, and it is keyed on the slug so running it twice produces one hotel
# rather than two.
#
# ## Two things about dates that decide whether the demo shows anything
#
# Everything here is created inside the last few weeks, deliberately.
# Retention::PurgeExpiredGuestDataJob runs daily in production and deletes guest
# chat after Retention::Policy::GUEST_CHAT_DAYS, and the analytics pages'
# MAX_DAYS is that same number — so plausible-looking "six months ago" data
# would both vanish overnight and be invisible on the very screens it was
# seeded to populate. That is the safe direction, but it reads as a bug to
# whoever is demoing.
#
# ## What it deliberately includes
#
# A demo that only shows the happy path invites exactly the question it does not
# answer. So this seeds an escalated conversation, a declined request, an
# overdue one, and questions the hotel could not answer — because "what happens
# when it doesn't know" is the first thing a sceptical hotelier asks.

demo_slug = "stari-grad-sarajevo"

# Useful at a console, pure noise in a suite that loads this file eleven times
# — see test/seeds/demo_seed_test.rb, which runs the real seed rather than
# asserting that the file parses.
report = ->(line) { puts line unless Rails.env.test? }

existing = Hotel.find_by(slug: demo_slug)
other_hotels = Hotel.where.not(slug: demo_slug).count

if other_hotels.positive?
  # The guard that makes running this against a real installation safe. A demo
  # hotel alongside real ones is confusing at best; the seed refuses rather than
  # deciding on somebody's behalf.
  report.call("Refusing to seed demo data: this database already has #{other_hotels} other hotel(s).")
  report.call("The demo seed is for an empty or demo-only installation. Nothing was changed.")
elsif existing
  report.call("Demo hotel #{demo_slug.inspect} already exists (##{existing.id}) — leaving it untouched.")
else
  ActiveRecord::Base.transaction do
    hotel = Hotel.create!(
      name: "Hotel Stari Grad Sarajevo",
      slug: demo_slug,
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
    )

    ActsAsTenant.with_tenant(hotel) do
      # --- The people ------------------------------------------------------
      #
      # Passwords are the same well-known demo string for all four. This seed
      # is for an empty or demo-only installation (see the guard above) and it
      # refuses to run alongside real hotels, which is what keeps that from
      # being a credential decision.
      admin = User.create!(
        hotel: hotel, name: "Mirza Sehović", email_address: "admin@stari-grad.demo",
        password: "password123", role: :hotel_admin, locale: "bs"
      )
      reception = [
        [ "Amira Hodžić", "amira@stari-grad.demo", "bs" ],
        [ "Dino Bešić", "dino@stari-grad.demo", "bs" ],
        [ "Lejla Kovač", "lejla@stari-grad.demo", "en" ]
      ].map do |name, email, locale|
        User.create!(hotel: hotel, name: name, email_address: email,
                     password: "password123", role: :staff, locale: locale)
      end

      # --- Rooms, two floors -----------------------------------------------
      rooms = (301..310).to_a.concat((401..408).to_a).map do |number|
        Room.create!(hotel: hotel, number: number.to_s)
      end
      room = ->(number) { rooms.find { |candidate| candidate.number == number.to_s } }

      # --- Departments and what each takes ----------------------------------
      housekeeping = Department.create!(hotel: hotel, name: "Domaćinstvo", position: 1)
      front_desk = Department.create!(hotel: hotel, name: "Recepcija", position: 2)
      kitchen = Department.create!(hotel: hotel, name: "Kuhinja", position: 3)
      maintenance = Department.create!(hotel: hotel, name: "Održavanje", position: 4)

      categories = {
        towels: [ housekeeping, "room_items", "Peškiri i posteljina", %w[quantity description], 1 ],
        cleaning: [ housekeeping, "cleaning", "Čišćenje sobe", %w[time description], 2 ],
        breakfast: [ kitchen, "room_service", "Posluga u sobu", %w[description time people], 3 ],
        taxi: [ front_desk, "taxi", "Taksi", %w[time people description], 4 ],
        late_checkout: [ front_desk, "late_checkout", "Kasna odjava", %w[time description], 5 ],
        repair: [ maintenance, "maintenance", "Kvar u sobi", %w[description], 6 ]
      }.transform_values do |(department, key, name, fields, position)|
        RequestCategory.create!(
          hotel: hotel, department: department, key: key, name: name,
          detail_fields: fields, position: position
        )
      end

      # --- The knowledge base -----------------------------------------------
      #
      # The part that decides whether the demo lands. Twenty thin entries read
      # as a template; twenty specific ones read as a real hotel — so every one
      # below names something concrete (a street, a time, a tram number) that a
      # generic hotel could not have written.
      [
        [ :dining, "Doručak",
          "Doručak se služi u restoranu na prvom spratu od 07:00 do 10:30, vikendom do 11:00. " \
          "Uključen je u cijenu sobe. Ako ranije putujete, javite nam večer prije i spakovaćemo vam " \
          "doručak za ponijeti." ],
        [ :dining, "Restoran i večera",
          "Naš restoran radi od 18:00 do 23:00. Nudimo bosansku kuhinju — begova čorba, japrak, " \
          "ćevapi — i vegetarijanska jela. Rezervacija nije obavezna, ali je preporučujemo vikendom." ],
        [ :dining, "Posluga u sobu",
          "Posluga u sobu dostupna je od 07:00 do 22:00. Meni se nalazi u fascikli na stolu u sobi." ],
        [ :dining, "Kafa i piće",
          "Lobi bar radi do ponoći. Bosanska kafa se služi na tradicionalan način, u džezvi." ],
        [ :policies, "Odjava",
          "Odjava je do 11:00. Kasna odjava do 14:00 moguća je uz doplatu od 20 KM, ovisno o " \
          "popunjenosti — pitajte recepciju na dan odlaska." ],
        [ :policies, "Prijava",
          "Prijava je od 14:00. Ako stižete ranije, čuvamo vaš prtljag besplatno na recepciji." ],
        [ :policies, "Pušenje",
          "Hotel je nepušački. Pušenje je dozvoljeno na terasi u dvorištu. Kazna za pušenje u sobi " \
          "je 100 KM." ],
        [ :policies, "Kućni ljubimci",
          "Mali kućni ljubimci do 10 kg su dobrodošli uz najavu i doplatu od 15 KM po noći." ],
        [ :policies, "Otkazivanje",
          "Besplatno otkazivanje do 48 sati prije dolaska. Nakon toga se naplaćuje prva noć." ],
        [ :facilities, "Wi-Fi",
          "Besplatan Wi-Fi u cijelom hotelu. Mreža: StariGradGuest. Lozinka je na kartici u sobi i " \
          "mijenja se sedmično." ],
        [ :facilities, "Parking",
          "Hotel ima 12 parking mjesta u dvorištu, 10 KM po noći, po dolasku. Stari Grad je pješačka " \
          "zona pa preporučujemo da rezervišete mjesto pri rezervaciji sobe." ],
        [ :facilities, "Klima i grijanje",
          "Sve sobe imaju klimu i grijanje sa zasebnom kontrolom. Ako nešto ne radi, javite " \
          "recepciji — održavanje dolazi isti dan." ],
        [ :facilities, "Praonica",
          "Usluga pranja i peglanja: predajte na recepciji do 09:00, vraćamo isti dan do 18:00." ],
        [ :facilities, "Bazen i spa",
          "Hotel nema bazen. Najbliži su termalni bazeni na Ilidži, oko 20 minuta tramvajem broj 3." ],
        [ :rooms, "Sef u sobi",
          "Svaka soba ima sef u ormaru. Ako ste zaboravili šifru, recepcija ga može otvoriti uz " \
          "provjeru dokumenta." ],
        [ :rooms, "Dodatni ležaj",
          "Dodatni ležaj je moguć u sobama 301–305, uz doplatu od 30 KM po noći." ],
        [ :local_area, "Baščaršija",
          "Baščaršija je 4 minute hoda od hotela. Sebilj, Gazi Husrev-begova džamija i kazandžijski " \
          "sokak su svi u krugu od 200 metara." ],
        [ :local_area, "Šta vidjeti",
          "U pješačkoj udaljenosti: Vijećnica (7 min), Latinska ćuprija (6 min), Tunel spasa je " \
          "20 minuta taksijem. Vidikovac Žuta tabija je 15 minuta uzbrdo — najljepše je pred zalazak." ],
        [ :local_area, "Preporuke za jelo",
          "Za ćevape: Željo ili Petica, oba na Baščaršiji. Za baklavu: Badem. Za kafu s pogledom: " \
          "Kafana Zlatna Ribica. Nemamo dogovor ni sa jednim od njih — to su mjesta gdje mi jedemo." ],
        [ :transport, "Aerodrom",
          "Aerodrom je 12 km, oko 20 minuta taksijem (25–30 KM). Možemo naručiti taksi — javite " \
          "recepciji ili pitajte mene ovdje." ],
        [ :transport, "Tramvaj",
          "Najbliža tramvajska stanica je Baščaršija, 5 minuta hoda. Karta se kupi na kiosku (1,80 KM) " \
          "ili kod vozača (2 KM) i mora se poništiti u vozilu." ]
      ].each_with_index do |(category, title, content), index|
        KbEntry.create!(
          hotel: hotel, category: category, title: title, content: content,
          published: true, position: index + 1
        )
      end

      # One deliberately unpublished, so the demo can show the draft/published
      # distinction — and so a reviewer can verify the concierge never quotes it.
      KbEntry.create!(
        hotel: hotel, category: :facilities, title: "Krovna terasa (u pripremi)",
        content: "NACRT — ne objavljivati dok se ne potvrdi datum otvaranja.",
        published: false, position: 99
      )

      # --- Guests and conversations ------------------------------------------
      #
      # Four languages, and the Arabic one matters most: it is the only way an
      # RTL rendering problem is visible before a demo rather than during one.
      guest = lambda do |name, locale, room_number, days_ago, phone: nil, channel: :web|
        GuestSession.create!(
          hotel: hotel, guest_name: name, locale: locale, room: room&.call(room_number),
          channel: channel, phone_e164: phone,
          privacy_accepted_at: days_ago.days.ago, expires_at: 21.days.from_now - days_ago.days,
          last_seen_at: days_ago.days.ago,
          token_digest: GuestSession.digest(SecureRandom.hex(16))
        )
      end

      say = lambda do |conversation, role, body, minutes_ago, locale: nil, visibility: :guest_visible, user: nil|
        conversation.messages.create!(
          hotel: hotel, sender_role: role, body: body, sender_user: user,
          body_locale: locale || conversation.guest_locale, visibility: visibility,
          created_at: minutes_ago.minutes.ago, updated_at: minutes_ago.minutes.ago
        )
      end

      # 1. Bosnian — a grounded answer, the ordinary case.
      bosnian = Conversation.create!(guest_session: guest.call("Emina Softić", "bs", "302", 2))
      say.call(bosnian, :guest, "Dobar dan! Do kada je doručak?", 2_880)
      say.call(bosnian, :assistant,
               "Dobar dan! Doručak se služi od 07:00 do 10:30, a vikendom do 11:00 — uključen je u " \
               "cijenu sobe. Ako ranije putujete, spakujemo vam doručak za ponijeti.", 2_879)
      say.call(bosnian, :guest, "Super, hvala!", 2_878)
      bosnian.update!(status: :resolved, last_message_at: 2_878.minutes.ago, staff_unread_count: 0)

      # 2. English — a request, gathered and confirmed, ending on the board.
      english_guest = guest.call("James Whitfield", "en", "305", 1)
      english = Conversation.create!(guest_session: english_guest)
      say.call(english, :guest, "Could I get two extra bath towels please?", 1_400)
      say.call(english, :assistant,
               "Of course — two bath towels for room 305. Shall I send that to reception?", 1_399)
      say.call(english, :guest, "Yes please", 1_398)
      say.call(english, :assistant,
               "Sent to reception — it's pending and someone will bring them up.", 1_397)
      english.update!(last_message_at: 1_397.minutes.ago, staff_unread_count: 0)

      # 3. German — the assistant hands over to a person. A demo that only shows
      #    the happy path invites exactly the question it does not answer.
      german_guest = guest.call("Klara Bergmann", "de", "401", 1)
      german = Conversation.create!(guest_session: german_guest)
      say.call(german, :guest,
               "Die Klimaanlage in meinem Zimmer macht ein lautes Geräusch, die ganze Nacht schon.", 300)
      say.call(german, :assistant,
               "Das tut mir leid — damit sollte sich jemand direkt ansehen. Ich habe die Rezeption " \
               "informiert, sie meldet sich persönlich bei Ihnen.", 299)
      say.call(german, :system,
               "The assistant handed this over (ai uncertain): Guest reports a loud air conditioning " \
               "unit in room 401, overnight. Needs maintenance.", 299, visibility: :internal)
      say.call(german, :staff, "Guten Morgen, Frau Bergmann — unser Techniker kommt in 20 Minuten vorbei.",
               120, locale: "bs", user: reception.first)
      german.update!(status: :escalated, escalation_reason: :ai_uncertain, escalated_at: 299.minutes.ago,
                     last_message_at: 120.minutes.ago, staff_unread_count: 0)

      # 4. Arabic — the RTL check, and on WhatsApp so the channel badge appears.
      arabic_guest = guest.call("سامي المنصوري", "ar", "403", 1,
                                phone: "+38761555777", channel: :whatsapp)
      arabic = Conversation.create!(guest_session: arabic_guest)
      arabic.update!(channel: :whatsapp)
      say.call(arabic, :guest, "مرحباً، هل يوجد مطعم حلال قريب من الفندق؟", 240)
      say.call(arabic, :assistant,
               "أهلاً بك! نعم — معظم المطاعم في باشتشارشيا تقدم طعاماً حلالاً، وهي على بعد 4 دقائق " \
               "سيراً على الأقدام. نوصي بمطعم Željo أو Petica للتشيفابي.", 239)
      say.call(arabic, :guest, "شكراً جزيلاً", 238)
      arabic.update!(last_message_at: 238.minutes.ago, staff_unread_count: 1)

      # 5. A guest still waiting — so the inbox has something needing attention
      #    when the demo opens it.
      waiting = Conversation.create!(guest_session: guest.call("Nikola Jovanović", "bs", "306", 0))
      say.call(waiting, :guest, "Mogu li dobiti račun na firmu? Trebaju mi podaci za fakturu.", 12)
      waiting.update!(last_guest_message_at: 12.minutes.ago, last_message_at: 12.minutes.ago,
                      staff_unread_count: 1)

      # --- Requests, in every status -----------------------------------------
      request = lambda do |category, guest_session, conversation, summary, details, status, created_minutes_ago, **extra|
        ServiceRequest.create!(
          hotel: hotel, conversation: conversation, guest_session: guest_session,
          room: guest_session.room, request_category: category, department: category.department,
          summary: summary, details: details, channel: conversation&.channel || "web",
          status: status, created_at: created_minutes_ago.minutes.ago,
          dedupe_key: SecureRandom.hex(16), **extra
        )
      end

      request.call(categories[:towels], english_guest, english, "Peškiri i posteljina — 2 peškira za kupanje",
                   { "quantity" => "2", "description" => "peškiri za kupanje" }, :new, 20)

      request.call(categories[:breakfast], english_guest, english, "Posluga u sobu — doručak u 08:00",
                   { "description" => "doručak za dvoje", "time" => "08:00", "people" => "2" },
                   :accepted, 90, acknowledged_at: 75.minutes.ago, acknowledged_by: reception.first)

      request.call(categories[:cleaning], arabic_guest, arabic, "Čišćenje sobe — poslije 14:00",
                   { "time" => "14:00", "description" => "soba 403" },
                   :in_progress, 200, acknowledged_at: 180.minutes.ago, acknowledged_by: reception.second)

      request.call(categories[:taxi], english_guest, english, "Taksi — aerodrom, 05:30",
                   { "time" => "05:30", "people" => "1", "description" => "za aerodrom" },
                   :completed, 1_400, acknowledged_at: 1_390.minutes.ago,
                   acknowledged_by: reception.first, completed_at: 1_300.minutes.ago)

      request.call(categories[:late_checkout], german_guest, german, "Kasna odjava — do 16:00",
                   { "time" => "16:00", "description" => "let u 19:00" }, :declined, 800,
                   acknowledged_at: 790.minutes.ago, acknowledged_by: admin)

      # A guest changed their mind — the ordinary way a request is cancelled,
      # and the last status needed for the board to show all six.
      request.call(categories[:taxi], german_guest, german, "Taksi — u grad, 19:00",
                   { "time" => "19:00", "people" => "2", "description" => "do Vijećnice" },
                   :cancelled, 600)

      # Older than the hotel's own 60-minute threshold and still nobody's — so
      # the board opens with a genuinely overdue card rather than a tidy one.
      request.call(categories[:repair], german_guest, german, "Kvar u sobi — klima pravi buku",
                   { "description" => "klima u sobi 401 pravi glasnu buku cijelu noć" }, :new, 240)

      # --- What the hotel could not answer -----------------------------------
      #
      # The knowledge-gap screen is empty on a fresh install, and an empty
      # screen cannot demonstrate the loop it exists for.
      [
        [ "Is there a swimming pool at the hotel?", "Ima li hotel bazen?", "bs", 4 ],
        [ "Do you have a shuttle to the airport?", "Habt ihr einen Flughafen-Shuttle?", "de", 2 ],
        [ "Can I store luggage after checkout?", nil, "en", 1 ]
      ].each do |question, original, locale, times|
        times.times do
          UnansweredQuestion.record!(hotel: hotel, question: question,
                                     question_original: original, locale: locale)
        end
      end

      # --- Usage, so the analytics pages are not empty ------------------------
      #
      # Spread across the last three weeks and inside GUEST_CHAT_DAYS, so the
      # default 30-day range shows a shape rather than one spike.
      21.times do |days_ago|
        replies = 3 + (days_ago % 5)
        replies.times do
          travel_days = days_ago
          AiRun.create!(
            hotel: hotel, kind: :reply, status: :success, model: "claude-opus-5",
            input_tokens: 1_800 + rand(900), output_tokens: 90 + rand(120),
            cache_read_tokens: 1_500 + rand(300), latency_ms: 900 + rand(1_400),
            created_at: travel_days.days.ago, updated_at: travel_days.days.ago
          )
        end
        AiRun.create!(
          hotel: hotel, kind: :translation, status: :success, model: "claude-haiku-4-5",
          input_tokens: 120 + rand(80), output_tokens: 60 + rand(40), latency_ms: 300 + rand(400),
          created_at: days_ago.days.ago, updated_at: days_ago.days.ago
        )
      end
      # A couple of failures, so "times it could not" is not a suspicious zero.
      AiRun.create!(hotel: hotel, kind: :reply, status: :timeout, model: "claude-opus-5",
                    input_tokens: 1_900, latency_ms: 25_000, error_class: "Ai::TimeoutError",
                    created_at: 3.days.ago, updated_at: 3.days.ago)

      # ai_usage_days is written by AiRun's own after_create_commit and needs
      # nothing here. It briefly had an explicit AiUsageDay.rebuild_for(hotel)
      # at this point, added when those callbacks were silently failing
      # (NoTenantSet — a commit fires outside the with_tenant block above; see
      # AiUsageDay.record!). Once that was fixed the rebuild became a second
      # writer: it *replaces* a day's counters and the callbacks then *add* to
      # them, so every number came out exactly doubled. Do not put it back.

      report.call("Seeded demo hotel #{hotel.name.inspect} (/h/#{hotel.slug}).")
      report.call("  Sign in: #{admin.email_address} / password123 (hotel admin)")
      report.call("  Reception: #{reception.map(&:email_address).join(', ')}")
      report.call(
        "  #{hotel.rooms.count} rooms · #{hotel.kb_entries.published.count} published knowledge entries · " \
        "#{hotel.conversations.count} conversations · #{hotel.service_requests.count} requests"
      )
    end
  end
end
