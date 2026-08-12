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
  SLUG = "stari-grad-sarajevo".freeze

  # --- The two guards ---------------------------------------------------------

  # Someone will eventually run this against production. A demo hotel sitting
  # alongside real ones is confusing at best, so the seed refuses rather than
  # deciding on anybody's behalf.
  test "it refuses to run when the database already holds hotels it did not create" do
    assert Hotel.where.not(slug: SLUG).exists?, "precondition: the fixtures ship other hotels"

    assert_no_difference -> { Hotel.count } do
      load SEED
    end
  end

  test "running it twice produces one hotel, not two" do
    clear_other_hotels
    load SEED
    load SEED

    assert_equal 1, Hotel.where(slug: SLUG).count
  end

  # --- The shape a demo depends on --------------------------------------------

  test "it seeds a hotel that is ready to present" do
    seed!

    hotel = Hotel.find_by!(slug: SLUG)
    with_tenant(hotel) do
      assert_equal "Europe/Sarajevo", hotel.timezone
      assert_equal "bs", hotel.staff_locale
      assert hotel.welcome_message.present?, "the landing page would look unfinished without one"
      assert_operator hotel.rooms.count, :>=, 10
      assert_equal 1, hotel.users.where(role: :hotel_admin).count
      assert_operator hotel.users.where(role: :staff).count, :>=, 3
      assert_operator hotel.departments.count, :>=, 3
      assert_operator hotel.request_categories.count, :>=, 4
    end
  end

  # The part that decides whether the demo lands. Twenty thin entries read as a
  # template; the count is the cheap half of that and the only half a test can
  # check.
  test "the knowledge base is substantial enough to answer real questions" do
    seed!

    with_tenant(hotel) do
      assert_operator hotel.published_kb_entries.count, :>=, 20
      # One deliberately unpublished, so a demo can show the draft/published
      # distinction — and so a reviewer can confirm the concierge never quotes it.
      assert hotel.kb_entries.where(published: false).exists?
    end
  end

  # The Arabic conversation matters most: it is the only way an RTL rendering
  # problem is visible before a demo rather than during one.
  test "there are conversations in all four supported languages" do
    seed!

    with_tenant(hotel) do
      assert_equal %w[ar bs de en], hotel.conversations.pluck(:guest_locale).uniq.sort
    end
  end

  # A demo that only shows the happy path invites exactly the question it does
  # not answer, so the seed has to contain the answer.
  test "one conversation shows the assistant handing over to a person" do
    seed!

    with_tenant(hotel) do
      escalated = hotel.conversations.where.not(escalated_at: nil)

      assert escalated.exists?, "a sceptical hotelier asks what happens when it does not know"
      assert escalated.first.messages.where(sender_role: :staff).exists?,
        "and the answer is only convincing if a person actually replied"
    end
  end

  test "the reception inbox opens with something waiting" do
    seed!

    with_tenant(hotel) { assert Conversation.needs_attention.exists? }
  end

  # Every status, so the board is not a row of identical cards — including the
  # two a hotel most wants to see handled: one late, one refused.
  test "the request board shows every status, including an overdue and a declined one" do
    seed!

    with_tenant(hotel) do
      assert_equal ServiceRequest.statuses.keys.sort, hotel.service_requests.pluck(:status).uniq.sort
      # Specifically one nobody has picked up: an accepted request that has
      # been sitting a while is also overdue, so asserting on `open_requests`
      # alone passes even when the unclaimed one is fresh — measured.
      assert hotel.service_requests.status_new.any?(&:overdue?),
        "the board needs a genuinely late card that nobody has claimed"
    end
  end

  test "the knowledge-gap screen has something on it" do
    seed!

    with_tenant(hotel) do
      assert_operator hotel.unanswered_questions.open_gaps.count, :>=, 2
      assert_operator hotel.unanswered_questions.maximum(:asked_count), :>, 1,
        "a repeat count is what makes the list worth ordering"
    end
  end

  # --- The two things that would make the demo silently empty -------------------

  # Anything older than GUEST_CHAT_DAYS is deleted by the nightly purge and is
  # invisible to the analytics pages, whose MAX_DAYS is that same number. A
  # seed that writes plausible "six months ago" data is a seed whose data
  # disappears overnight.
  test "nothing is seeded outside the retention window" do
    seed!

    with_tenant(hotel) do
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
  test "the analytics pages have something to show" do
    seed!

    with_tenant(hotel) do
      report = Analytics::HotelReport.new(hotel: hotel)

      # Exactly the ai_runs that exist, not merely "some". The seed once had
      # an explicit rebuild alongside AiRun's own after_create_commit — one
      # replacing a day's counters and the other adding to them — and every
      # number came out doubled. A `> 50` assertion passes just as happily
      # against double as against right.
      assert_equal hotel.ai_runs.count, report.ai_runs
      assert_operator report.ai_runs, :>, 50, "and enough of them for a chart to have a shape"
      assert_operator report.tokens, :>, 0
      assert_operator report.ai_failures, :>, 0, "a suspicious zero is worse than an honest failure"
      assert_operator report.guests, :>, 0
      assert report.top_unanswered.any?
    end
  end

  private
    def hotel = Hotel.find_by!(slug: SLUG)

    def seed!
      clear_other_hotels
      load SEED
    end

    # The fixtures ship two hotels, and the seed deliberately refuses to run
    # beside them. Cleared inside the test transaction, so nothing escapes it.
    def clear_other_hotels
      Hotel.where.not(slug: SLUG).find_each(&:destroy)
    end
end
