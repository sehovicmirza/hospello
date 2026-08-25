require "test_helper"

# The demo seed, actually loaded — not "the file parses".
#
# A demo seed that broke three slices ago and nobody noticed is the normal
# failure mode for this kind of file: nothing in the app calls it, no page
# renders it, and it is only ever run by a person who is about to stand in
# front of a hotel manager. So this asserts the shape a demo actually depends
# on, and the two guards that make running it against production safe.
#
# The fixtures are cleared first because the seed refuses to run alongside
# hotels it did not create — which is the point of the first test below.
class DemoSeedTest < ActiveSupport::TestCase
  SEED = Rails.root.join("db/seeds/demo.rb")

  # Written out rather than read from DemoCatalogue on purpose. Deriving the
  # expected list from the thing under test would mean a hotel silently
  # dropped from the catalogue makes this suite quietly check four hotels
  # instead of five and still pass — the exact circularity the engineering
  # rules warn about. The catalogue is asserted against this list below, so
  # adding a prospect is a two-line change and forgetting one is a red test.
  DEMO_SLUGS = %w[
    stari-grad-sarajevo
    hotel-hills-sarajevo
    hotel-hollywood-sarajevo
    hotel-vema-visoko
    ibis-styles-sarajevo
  ].freeze

  # --- The two guards ---------------------------------------------------------

  # Someone will eventually run this against production. A demo hotel sitting
  # alongside real ones is confusing at best, so the seed refuses rather than
  # deciding on anybody's behalf.
  test "it refuses to run when the database already holds hotels it did not create" do
    assert Hotel.where.not(slug: DEMO_SLUGS).exists?, "precondition: the fixtures ship other hotels"

    assert_no_difference -> { Hotel.count } do
      load SEED
    end
  end

  test "running it twice produces one of each hotel, not two" do
    clear_other_hotels
    load SEED
    load SEED

    DEMO_SLUGS.each do |slug|
      assert_equal 1, Hotel.where(slug: slug).count, "#{slug} was seeded twice"
    end
  end

  # The guard is evaluated once, against the whole set, before any hotel is
  # built. Checked per hotel instead, demo hotel #1 would count as "another
  # hotel" when #2 ran and nothing past the first would ever seed — which
  # would look like the seed working, since one hotel did appear.
  test "every hotel in the catalogue is seeded, not just the first" do
    seed!

    assert_equal DEMO_SLUGS.sort, Hotel.pluck(:slug).sort
  end

  # A half-seeded set completes on the next run rather than being skipped
  # wholesale because one of them happens to exist.
  test "a missing hotel is rebuilt without disturbing the others" do
    seed!
    removed = Hotel.find_by!(slug: DEMO_SLUGS.last)
    untouched_id = Hotel.find_by!(slug: DEMO_SLUGS.first).id
    with_tenant(removed) { removed.destroy }

    load SEED

    assert_equal DEMO_SLUGS.sort, Hotel.pluck(:slug).sort
    assert_equal untouched_id, Hotel.find_by!(slug: DEMO_SLUGS.first).id,
      "the hotels that already existed should have been left alone, not rebuilt"
  end

  # --- The shape a demo depends on --------------------------------------------

  test "every hotel is ready to present" do
    seed!

    each_demo_hotel do |hotel|
      assert_equal "Europe/Sarajevo", hotel.timezone
      assert_includes Hotel::STAFF_LOCALES, hotel.staff_locale
      assert hotel.welcome_message.present?, "the landing page would look unfinished without one"
      assert hotel.contact_phone.present?, "a guest with a real problem needs a number to call"
      assert_operator hotel.rooms.count, :>=, 10
      assert_equal 1, hotel.users.where(role: :hotel_admin).count
      assert_operator hotel.users.where(role: :staff).count, :>=, 3

      # Departments and categories exist only to route service requests, so a
      # hotel that takes none should have neither. Asserted in both directions:
      # a Service hotel missing its board is as broken a demo as an Essentials
      # hotel carrying one.
      if hotel.plan_allows?(:requests)
        assert_operator hotel.departments.count, :>=, 3
        assert_operator hotel.request_categories.count, :>=, 4
      else
        assert_equal 0, hotel.departments.count, "#{hotel.slug}: Essentials seeded a department"
        assert_equal 0, hotel.request_categories.count, "#{hotel.slug}: Essentials seeded a category"
      end
    end
  end

  # The plan being sold first has to be demonstrable, so exactly one hotel runs
  # on it. Pinned by slug, not by count: "some hotel is on Essentials" would
  # stay green if the wrong one moved.
  test "one hotel runs on Essentials so the plan being sold can be shown" do
    seed!

    essentials = Hotel.where(plan: :essentials).pluck(:slug)

    assert_equal [ "hotel-vema-visoko" ], essentials
    assert_equal 4, Hotel.where(plan: :service).count
  end

  # A guest of the Essentials hotel must reach a working concierge — the whole
  # product — while the request machinery stays absent.
  test "the Essentials hotel has everything its plan does include" do
    seed!
    hotel = Hotel.find_by!(slug: "hotel-vema-visoko")

    with_tenant(hotel) do
      assert_equal 0, hotel.service_requests.count, "Essentials must not seed a request board"
      assert_operator hotel.published_kb_entries.count, :>=, 15, "Q&A is the entire product here"
      assert_operator hotel.conversations.count, :>=, 3
      assert_operator hotel.rooms.count, :>=, 10
      assert_operator hotel.rooms.count, :<=, hotel.effective_room_limit,
        "the demo hotel must fit inside the ceiling its own plan enforces"
    end
  end

  # Switching between hotels mid-demo is how the multi-tenancy story gets told
  # without a slide, and it only lands if they visibly differ.
  test "the hotels are branded distinctly from one another" do
    seed!

    colours = Hotel.pluck(:primary_color)

    assert_equal colours.uniq.length, colours.length, "two demo hotels share a primary colour"
  end

  # The part that decides whether the demo lands. Twenty thin entries read as a
  # template; the count is the cheap half of that and the only half a test can
  # check.
  test "every hotel's knowledge base is substantial enough to answer real questions" do
    seed!

    each_demo_hotel do |hotel|
      assert_operator hotel.published_kb_entries.count, :>=, 20
      # One deliberately unpublished, so a demo can show the draft/published
      # distinction — and so a reviewer can confirm the concierge never quotes it.
      assert hotel.kb_entries.where(published: false).exists?
    end
  end

  # The Arabic conversation matters most: it is the only way an RTL rendering
  # problem is visible before a demo rather than during one.
  test "every hotel has conversations in all four supported languages" do
    seed!

    each_demo_hotel do |hotel|
      assert_equal %w[ar bs de en], hotel.conversations.pluck(:guest_locale).uniq.sort
    end
  end

  # A demo that only shows the happy path invites exactly the question it does
  # not answer, so the seed has to contain the answer.
  test "every hotel has a conversation where the assistant hands over to a person" do
    seed!

    each_demo_hotel do |hotel|
      escalated = hotel.conversations.where.not(escalated_at: nil)

      assert escalated.exists?, "a sceptical hotelier asks what happens when it does not know"
      assert escalated.first.messages.where(sender_role: :staff).exists?,
        "and the answer is only convincing if a person actually replied"
    end
  end

  test "every hotel's reception inbox opens with something waiting" do
    seed!

    each_demo_hotel { assert Conversation.needs_attention.exists? }
  end

  # Every status, so the board is not a row of identical cards — including the
  # two a hotel most wants to see handled: one late, one refused.
  test "every hotel's request board shows every status, including an overdue and a declined one" do
    seed!

    each_demo_hotel do |hotel|
      next unless hotel.plan_allows?(:requests)

      assert_equal ServiceRequest.statuses.keys.sort, hotel.service_requests.pluck(:status).uniq.sort
      # Specifically one nobody has picked up: an accepted request that has
      # been sitting a while is also overdue, so asserting on `open_requests`
      # alone passes even when the unclaimed one is fresh — measured.
      assert hotel.service_requests.status_new.any?(&:overdue?),
        "#{hotel.slug}: the board needs a genuinely late card that nobody has claimed"
    end
  end

  test "every hotel's knowledge-gap screen has something on it" do
    seed!

    each_demo_hotel do |hotel|
      assert_operator hotel.unanswered_questions.open_gaps.count, :>=, 2
      assert_operator hotel.unanswered_questions.maximum(:asked_count), :>, 1,
        "a repeat count is what makes the list worth ordering"
    end
  end

  # --- Isolation, which five tenants finally make demonstrable ------------------

  # The product's central promise, and now something the demo itself can show:
  # open two hotels side by side and neither knows the other exists. Worth a
  # test because a seed is the easiest place to accidentally wire one hotel's
  # room or category to another's.
  test "no hotel's records leak into another's" do
    seed!

    hotels = Hotel.where(slug: DEMO_SLUGS).to_a

    hotels.each do |hotel|
      with_tenant(hotel) do
        foreign_ids = hotels.reject { |other| other == hotel }.map(&:id)

        assert_empty hotel.rooms.where(hotel_id: foreign_ids)
        assert_empty hotel.kb_entries.where(hotel_id: foreign_ids)
        assert_empty hotel.conversations.where(hotel_id: foreign_ids)
        assert_empty hotel.service_requests.where(hotel_id: foreign_ids)
        # The one a seed gets wrong by hand: a category pointing at another
        # hotel's department. RequestCategory validates this, so a failure
        # here means the validation was bypassed.
        assert_empty hotel.request_categories.where.not(department_id: hotel.departments.select(:id))
      end
    end
  end

  # --- The two things that would make the demo silently empty -------------------

  # Anything older than GUEST_CHAT_DAYS is deleted by the nightly purge and is
  # invisible to the analytics pages, whose MAX_DAYS is that same number. A
  # seed that writes plausible "six months ago" data is a seed whose data
  # disappears overnight.
  test "nothing is seeded outside the retention window" do
    seed!

    each_demo_hotel do |hotel|
      cutoff = Retention::Policy.guest_chat_cutoff

      assert_operator hotel.conversations.minimum(:created_at), :>, cutoff
      assert_operator hotel.messages.minimum(:created_at), :>, cutoff
      assert_operator hotel.guest_sessions.minimum(:created_at), :>, cutoff
    end
  end

  # The analytics pages read ai_usage_days, not ai_runs. The rollup is written
  # by AiRun's own after_create_commit — which fires at commit, i.e. *outside*
  # the seed's tenant block — so this is also the regression test for the whole
  # seed silently producing empty analytics.
  test "every hotel's analytics pages have something to show" do
    seed!

    each_demo_hotel do |hotel|
      report = Analytics::HotelReport.new(hotel: hotel)

      # Exactly the ai_runs that exist, not merely "some". The seed once had
      # an explicit rebuild alongside AiRun's own after_create_commit — one
      # replacing a day's counters and the other adding to them — and every
      # number came out doubled. A `> 50` assertion passes just as happily
      # against double as against right.
      assert_equal hotel.ai_runs.count, report.ai_runs
      assert_operator report.ai_runs, :>, 30, "and enough of them for a chart to have a shape"
      assert_operator report.tokens, :>, 0
      assert_operator report.ai_failures, :>, 0, "a suspicious zero is worse than an honest failure"
      assert_operator report.guests, :>, 0
      assert report.top_unanswered.any?
    end
  end

  private
    def each_demo_hotel
      hotels = Hotel.where(slug: DEMO_SLUGS).to_a

      assert_equal DEMO_SLUGS.length, hotels.length,
        "expected every catalogue hotel to be seeded before asserting on them"

      hotels.each { |hotel| with_tenant(hotel) { yield hotel } }
    end

    def seed!
      clear_other_hotels
      load SEED
    end

    # The fixtures ship two hotels, and the seed deliberately refuses to run
    # beside them. Cleared inside the test transaction, so nothing escapes it.
    def clear_other_hotels
      Hotel.where.not(slug: DEMO_SLUGS).find_each { |hotel| with_tenant(hotel) { hotel.destroy } }
    end
end
