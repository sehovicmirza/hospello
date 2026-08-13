# Demo data: realistic, fully configured hotels that can be presented to a
# decision-maker without entering anything by hand.
#
# Loaded only when SEED_DEMO=1 (see db/seeds.rb). **Someone will eventually run
# this against production**, so it is built to make that safe rather than
# unlikely: it refuses outright if the database already holds a hotel it did not
# create, and it is keyed on the slug so running it twice produces one hotel
# rather than two.
#
# ## Why this is a catalogue rather than one script
#
# Four of these hotels are real businesses being approached as pilot candidates,
# so a sales conversation can open with "here is your hotel, running" rather
# than a slide. Each lives in its own file under db/seeds/demo/hotels/ as a
# plain data hash; this file owns the guards and does the building. Adding a
# fifth prospect should mean writing one data file, not touching this one.
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
# answer. So every hotel gets an escalated conversation, a declined request, an
# overdue one, and questions it could not answer — because "what happens when it
# doesn't know" is the first thing a sceptical hotelier asks.

# The catalogue. Each file under db/seeds/demo/hotels/ reopens this module with
# one `def self.<name>` returning a spec hash; re-defining a method on load is
# idempotent, which matters because test/seeds/demo_seed_test.rb loads this file
# once per test.
module DemoCatalogue
  # Order matters only for the console output and for which hotel a demo opens
  # on first. Stari Grad stays first: it is the fictional one, safe to show to
  # any audience without the real-brand question arising.
  # A method rather than a constant: this file is `load`ed once per test, and a
  # constant would warn "already initialized" on every reload.
  def self.hotel_names = %i[stari_grad hotel_hills hotel_hollywood hotel_vema ibis_styles]

  def self.all = hotel_names.map { |name| public_send(name) }
end

Dir[Rails.root.join("db/seeds/demo/hotels/*.rb")].sort.each { |file| load file }

# Builds one hotel from a spec hash. Everything it creates is inside
# ActsAsTenant.with_tenant, and it is the only place that knows the order
# records have to be made in.
class DemoHotelBuilder
  def initialize(spec, report:)
    @spec = spec
    @report = report
  end

  def build!
    ActiveRecord::Base.transaction do
      @hotel = Hotel.create!(**@spec.fetch(:hotel))

      ActsAsTenant.with_tenant(@hotel) do
        create_staff
        create_rooms
        create_departments_and_categories
        create_knowledge_base
        create_conversations
        create_requests
        create_unanswered_questions
        create_usage_history
        announce
      end
    end

    @hotel
  end

  private
    attr_reader :spec, :hotel

    # Passwords are the same well-known demo string for everyone. This seed is
    # for an empty or demo-only installation (see the guard in the caller) and
    # it refuses to run alongside real hotels, which is what keeps that from
    # being a credential decision. A method, not a constant, for the same
    # reload reason as hotel_names above.
    def demo_password = "password123"

    def create_staff
      admin_spec = @spec.fetch(:admin)
      @admin = User.create!(
        hotel: @hotel, name: admin_spec.fetch(:name), email_address: admin_spec.fetch(:email),
        password: demo_password, role: :hotel_admin, locale: admin_spec.fetch(:locale)
      )

      @reception = @spec.fetch(:reception).map do |person|
        User.create!(
          hotel: @hotel, name: person.fetch(:name), email_address: person.fetch(:email),
          password: demo_password, role: :staff, locale: person.fetch(:locale)
        )
      end
    end

    # Referenced from conversation and request specs by symbol, so a data file
    # never has to hold an ActiveRecord object.
    def user_for(reference)
      return nil if reference.nil?
      return @admin if reference == :admin

      @reception.fetch(reference.to_s.delete_prefix("reception_").to_i)
    end

    def create_rooms
      @rooms = @spec.fetch(:room_numbers).map { |number| Room.create!(hotel: @hotel, number: number.to_s) }
    end

    def room_for(number)
      return nil if number.nil?

      @rooms.find { |candidate| candidate.number == number.to_s }
    end

    def create_departments_and_categories
      @departments = @spec.fetch(:departments).each_with_index.to_h do |(key, name), index|
        [ key, Department.create!(hotel: @hotel, name: name, position: index + 1) ]
      end

      @categories = @spec.fetch(:categories).each_with_index.to_h do |(key, attributes), index|
        [
          key,
          RequestCategory.create!(
            hotel: @hotel, department: @departments.fetch(attributes.fetch(:department)),
            key: attributes.fetch(:key), name: attributes.fetch(:name),
            detail_fields: attributes.fetch(:detail_fields), position: index + 1
          )
        ]
      end
    end

    # The part that decides whether the demo lands. Twenty thin entries read as
    # a template; twenty specific ones read as a real hotel — so every entry in
    # the data files names something concrete that a generic hotel could not
    # have written, and each is marked SOURCED or INVENTED so a later reader
    # knows which lines may be corrected freely.
    def create_knowledge_base
      @spec.fetch(:knowledge).each_with_index do |entry, index|
        KbEntry.create!(
          hotel: @hotel, category: entry.fetch(:category), title: entry.fetch(:title),
          content: entry.fetch(:content), published: entry.fetch(:published, true),
          position: entry.fetch(:position, index + 1)
        )
      end
    end

    def create_conversations
      @conversations = {}
      @guest_sessions = {}

      @spec.fetch(:conversations).each do |conversation_spec|
        guest_spec = conversation_spec.fetch(:guest)
        days_ago = guest_spec.fetch(:days_ago)

        session = GuestSession.create!(
          hotel: @hotel, guest_name: guest_spec.fetch(:name), locale: guest_spec.fetch(:locale),
          room: room_for(guest_spec[:room]), channel: guest_spec.fetch(:channel, :web),
          phone_e164: guest_spec[:phone],
          privacy_accepted_at: days_ago.days.ago,
          expires_at: 21.days.from_now - days_ago.days,
          last_seen_at: days_ago.days.ago,
          token_digest: GuestSession.digest(SecureRandom.hex(16))
        )

        conversation = Conversation.create!(guest_session: session)
        conversation.update!(channel: :whatsapp) if guest_spec.fetch(:channel, :web) == :whatsapp

        conversation_spec.fetch(:messages).each do |message|
          conversation.messages.create!(
            hotel: @hotel, sender_role: message.fetch(:role), body: message.fetch(:body),
            sender_user: user_for(message[:user]),
            body_locale: message.fetch(:locale, conversation.guest_locale),
            visibility: message.fetch(:visibility, :guest_visible),
            created_at: message.fetch(:minutes_ago).minutes.ago,
            updated_at: message.fetch(:minutes_ago).minutes.ago
          )
        end

        conversation.update!(**conversation_attributes(conversation_spec))

        key = conversation_spec.fetch(:key)
        @conversations[key] = conversation
        @guest_sessions[key] = session
      end
    end

    def conversation_attributes(conversation_spec)
      attributes = { last_message_at: conversation_spec.fetch(:last_message_minutes_ago).minutes.ago }
      attributes[:status] = conversation_spec[:status] if conversation_spec[:status]
      attributes[:staff_unread_count] = conversation_spec.fetch(:staff_unread_count, 0)

      if conversation_spec[:escalation_reason]
        attributes[:escalation_reason] = conversation_spec.fetch(:escalation_reason)
        attributes[:escalated_at] = conversation_spec.fetch(:escalated_minutes_ago).minutes.ago
      end

      if conversation_spec[:last_guest_message_minutes_ago]
        attributes[:last_guest_message_at] = conversation_spec.fetch(:last_guest_message_minutes_ago).minutes.ago
      end

      attributes
    end

    def create_requests
      @spec.fetch(:requests).each do |request_spec|
        conversation = @conversations.fetch(request_spec.fetch(:conversation))
        session = @guest_sessions.fetch(request_spec.fetch(:conversation))
        category = @categories.fetch(request_spec.fetch(:category))

        extra = {}
        if request_spec[:acknowledged_minutes_ago]
          extra[:acknowledged_at] = request_spec.fetch(:acknowledged_minutes_ago).minutes.ago
          extra[:acknowledged_by] = user_for(request_spec.fetch(:acknowledged_by))
        end
        extra[:completed_at] = request_spec.fetch(:completed_minutes_ago).minutes.ago if request_spec[:completed_minutes_ago]

        ServiceRequest.create!(
          hotel: @hotel, conversation: conversation, guest_session: session,
          room: session.room, request_category: category, department: category.department,
          summary: request_spec.fetch(:summary), details: request_spec.fetch(:details),
          channel: conversation.channel, status: request_spec.fetch(:status),
          created_at: request_spec.fetch(:minutes_ago).minutes.ago,
          dedupe_key: SecureRandom.hex(16), **extra
        )
      end
    end

    # The knowledge-gap screen is empty on a fresh install, and an empty screen
    # cannot demonstrate the loop it exists for.
    def create_unanswered_questions
      @spec.fetch(:unanswered).each do |gap|
        gap.fetch(:times).times do
          UnansweredQuestion.record!(
            hotel: @hotel, question: gap.fetch(:question),
            question_original: gap[:original], locale: gap.fetch(:locale)
          )
        end
      end
    end

    # Spread across recent weeks and inside GUEST_CHAT_DAYS, so the analytics
    # pages show a shape rather than one spike.
    #
    # ai_usage_days is written by AiRun's own after_create_commit and needs
    # nothing here. It briefly had an explicit AiUsageDay.rebuild_for(hotel) at
    # this point, added when those callbacks were silently failing (NoTenantSet
    # — a commit fires outside the with_tenant block above; see
    # AiUsageDay.record!). Once that was fixed the rebuild became a second
    # writer: it *replaces* a day's counters and the callbacks then *add* to
    # them, so every number came out exactly doubled. Do not put it back.
    def create_usage_history
      days = @spec.fetch(:usage_history_days)

      days.times do |days_ago|
        (3 + (days_ago % 5)).times do
          AiRun.create!(
            hotel: @hotel, kind: :reply, status: :success, model: "claude-opus-5",
            input_tokens: 1_800 + rand(900), output_tokens: 90 + rand(120),
            cache_read_tokens: 1_500 + rand(300), latency_ms: 900 + rand(1_400),
            created_at: days_ago.days.ago, updated_at: days_ago.days.ago
          )
        end

        AiRun.create!(
          hotel: @hotel, kind: :translation, status: :success, model: "claude-haiku-4-5",
          input_tokens: 120 + rand(80), output_tokens: 60 + rand(40), latency_ms: 300 + rand(400),
          created_at: days_ago.days.ago, updated_at: days_ago.days.ago
        )
      end

      # A failure, so "times it could not" is not a suspicious zero.
      AiRun.create!(
        hotel: @hotel, kind: :reply, status: :timeout, model: "claude-opus-5",
        input_tokens: 1_900, latency_ms: 25_000, error_class: "Ai::TimeoutError",
        created_at: 3.days.ago, updated_at: 3.days.ago
      )
    end

    def announce
      @report.call("Seeded demo hotel #{@hotel.name.inspect} (/h/#{@hotel.slug}).")
      @report.call("  Sign in: #{@admin.email_address} / #{demo_password} (hotel admin)")
      @report.call("  Reception: #{@reception.map(&:email_address).join(', ')}")
      @report.call(
        "  #{@hotel.rooms.count} rooms · #{@hotel.kb_entries.published.count} published knowledge entries · " \
        "#{@hotel.conversations.count} conversations · #{@hotel.service_requests.count} requests"
      )
    end
end

# --- Run it ------------------------------------------------------------------

# Useful at a console, pure noise in a suite that loads this file once per test
# — see test/seeds/demo_seed_test.rb, which runs the real seed rather than
# asserting that the file parses.
report = ->(line) { puts line unless Rails.env.test? }

specs = DemoCatalogue.all
demo_slugs = specs.map { |spec| spec.fetch(:hotel).fetch(:slug) }

# The guard that makes running this against a real installation safe. A demo
# hotel alongside real ones is confusing at best; the seed refuses rather than
# deciding on somebody's behalf.
#
# Evaluated ONCE, before the loop, against the whole set. Checking it per hotel
# instead would count demo hotel #1 as "another hotel" when #2 runs, and nothing
# past the first would ever seed.
foreign_hotels = Hotel.where.not(slug: demo_slugs).count

if foreign_hotels.positive?
  report.call("Refusing to seed demo data: this database already has #{foreign_hotels} hotel(s) the demo did not create.")
  report.call("The demo seed is for an empty or demo-only installation. Nothing was changed.")
else
  specs.each do |spec|
    slug = spec.fetch(:hotel).fetch(:slug)
    existing = Hotel.find_by(slug: slug)

    # Per hotel, so a half-seeded set completes on the next run rather than
    # being skipped wholesale because one of them already exists.
    if existing
      report.call("Demo hotel #{slug.inspect} already exists (##{existing.id}) — leaving it untouched.")
    else
      DemoHotelBuilder.new(spec, report: report).build!
    end
  end
end
