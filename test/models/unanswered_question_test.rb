require "test_helper"

# The point of this model is that a hotel can see what it repeatedly fails to
# answer. Everything asserted here serves that: a list that shows the same
# question four times with a count of 1 each is a list nobody reads, and a
# question that silently merges with a different one is worse still because
# the second question is simply gone.
class UnansweredQuestionTest < ActiveSupport::TestCase
  setup { @hotel = hotels(:stari_grad) }

  test "records a gap the first time it is asked" do
    with_tenant(@hotel) do
      question = UnansweredQuestion.record!(
        hotel: @hotel, question: "Is there a pool?",
        question_original: "Ima li bazen?", locale: "bs"
      )

      assert question.persisted?
      assert_equal 1, question.asked_count
      assert question.status_new?
      assert_equal "Ima li bazen?", question.question_original
    end
  end

  test "the same question asked again counts, rather than creating a second row" do
    with_tenant(@hotel) do
      first = UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?")
      second = UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?")

      assert_equal first.id, second.id
      assert_equal 2, second.asked_count
      assert_equal 1, @hotel.unanswered_questions.count
    end
  end

  # Case, punctuation and spacing are noise. A hotel seeing these as three
  # separate gaps would conclude the feature is broken.
  test "case, punctuation and spacing do not make a new gap" do
    with_tenant(@hotel) do
      UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?")
      UnansweredQuestion.record!(hotel: @hotel, question: "is there a pool")
      last = UnansweredQuestion.record!(hotel: @hotel, question: "Is  there  a POOL ?")

      assert_equal 1, @hotel.unanswered_questions.count
      assert_equal 3, last.asked_count
    end
  end

  # The other direction, and the more important one: a false merge hides a
  # question outright, where a false split is merely untidy and visible.
  test "genuinely different questions stay separate" do
    with_tenant(@hotel) do
      UnansweredQuestion.record!(hotel: @hotel, question: "Can I book a taxi?")
      UnansweredQuestion.record!(hotel: @hotel, question: "Can I book a table?")

      assert_equal 2, @hotel.unanswered_questions.count
    end
  end

  test "two hotels each keep their own copy of the same question" do
    with_tenant(@hotel) { UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?") }
    with_tenant(hotels(:vrelo)) do
      UnansweredQuestion.record!(hotel: hotels(:vrelo), question: "Is there a pool?")
    end

    assert_equal 1, with_tenant(@hotel) { @hotel.unanswered_questions.count }
    assert_equal 1, with_tenant(hotels(:vrelo)) { hotels(:vrelo).unanswered_questions.count }
  end

  # A hotel that decided a question was not worth answering should not have
  # that decision undone by the next guest who asks it.
  test "a repeat does not reopen a dismissed question or overwrite its text" do
    with_tenant(@hotel) do
      first = UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?", question_original: "Ima li bazen?")
      first.update!(status: :dismissed)

      again = UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?", question_original: "Gibt es einen Pool?")

      assert again.status_dismissed?
      assert_equal "Ima li bazen?", again.question_original
      assert_equal 2, again.asked_count
    end
  end

  # Deduplication is the database's job, not Ruby's: two guests asking the
  # same thing in the same second is exactly the race a find-then-create
  # loses. Simulated by letting the insert lose to a row that already exists.
  test "a lost insert race counts in rather than raising" do
    with_tenant(@hotel) do
      UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?")

      # A second caller that checked before the first one committed would
      # arrive here: no row in its view, so it inserts, and Postgres rejects it.
      duplicate = UnansweredQuestion.new(
        hotel: @hotel, question: "Is there a pool?",
        normalized_hash: UnansweredQuestion.normalize_and_digest("Is there a pool?")
      )
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }

      counted = UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?")

      assert_equal 2, counted.asked_count
      assert_equal 1, @hotel.unanswered_questions.count
    end
  end

  test "open gaps come back most-asked first" do
    with_tenant(@hotel) do
      once = UnansweredQuestion.record!(hotel: @hotel, question: "Is there a sauna?")
      3.times { UnansweredQuestion.record!(hotel: @hotel, question: "Is there a pool?") }
      answered = UnansweredQuestion.record!(hotel: @hotel, question: "Where is the gym?")
      answered.update!(status: :answered)

      gaps = UnansweredQuestion.open_gaps.to_a

      assert_equal [ 3, 1 ], gaps.map(&:asked_count)
      assert_not_includes gaps, answered
      assert_includes gaps, once
    end
  end

  # The model's own output can be arbitrarily long; the column and the staff
  # screen are not.
  test "an over-long question is truncated rather than rejected" do
    with_tenant(@hotel) do
      question = UnansweredQuestion.record!(hotel: @hotel, question: "a" * 900)

      assert question.persisted?
      assert_operator question.question.length, :<=, UnansweredQuestion::MAX_QUESTION_LENGTH
    end
  end
end
