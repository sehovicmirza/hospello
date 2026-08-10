require "test_helper"

# The knowledge base is the only source the Slice 3 concierge may answer a
# hotel question from, so the guarantees here are about what can and cannot
# reach a guest: drafts cannot, another hotel's entries cannot, and the
# order the entries come out in has to be identical every time or the
# prompt cache never hits.
class KbEntryTest < ActiveSupport::TestCase
  test "an entry is a draft unless it is deliberately published" do
    with_tenant(hotels(:stari_grad)) do
      entry = hotels(:stari_grad).kb_entries.create!(title: "Brand new entry", content: "Half-written.")

      assert_not entry.published?, "a new entry must never be publishable by omission — it reaches guests"
    end
  end

  # The include half is asserted alongside the exclude half: a scope that
  # returned nothing at all would satisfy "drafts are excluded" on its own.
  test "the published scope returns published entries and excludes drafts" do
    with_tenant(hotels(:stari_grad)) do
      hotel = hotels(:stari_grad)
      live = hotel.kb_entries.create!(title: "Breakfast", content: "07:00-10:30.", published: true)
      draft = hotel.kb_entries.create!(title: "Spa", content: "Still deciding.", published: false)

      published_ids = hotel.kb_entries.published.pluck(:id)

      assert_includes published_ids, live.id
      assert_not_includes published_ids, draft.id
    end
  end

  # The prompt is cached on an exact prefix match, so two entries sharing a
  # position must still come out in the same order on every single build.
  # Postgres gives no ordering guarantee for ties, so the id tiebreak is
  # load-bearing rather than tidy.
  test "ordered is deterministic when positions tie" do
    with_tenant(hotels(:stari_grad)) do
      hotel = hotels(:stari_grad)
      first = hotel.kb_entries.create!(title: "Tie A", content: "a", position: 5)
      second = hotel.kb_entries.create!(title: "Tie B", content: "b", position: 5)
      earlier = hotel.kb_entries.create!(title: "Earlier", content: "c", position: 1)

      expected = [ earlier.id, first.id, second.id ]

      5.times { assert_equal expected, hotel.kb_entries.ordered.pluck(:id) }
    end
  end

  test "content over 2000 characters is rejected with a message a hotel manager could act on" do
    with_tenant(hotels(:stari_grad)) do
      entry = hotels(:stari_grad).kb_entries.build(title: "Far too long", content: "a" * 2001)

      assert_not entry.valid?
      assert_includes entry.errors[:content],
        "is too long — please keep an entry under 2000 characters, and split long topics into separate entries"
    end
  end

  test "content of exactly 2000 characters is accepted" do
    with_tenant(hotels(:stari_grad)) do
      entry = hotels(:stari_grad).kb_entries.build(title: "Exactly at the cap", content: "a" * 2000)

      assert entry.valid?, entry.errors.full_messages.to_sentence
    end
  end

  test "a title and content are both required" do
    with_tenant(hotels(:stari_grad)) do
      entry = hotels(:stari_grad).kb_entries.build(title: " ", content: " ")

      assert_not entry.valid?
      assert_includes entry.errors[:title], "can't be blank"
      assert_includes entry.errors[:content], "can't be blank"
    end
  end

  test "a title is unique within a hotel" do
    with_tenant(hotels(:stari_grad)) do
      hotels(:stari_grad).kb_entries.create!(title: "Breakfast times", content: "07:00-10:30.")
      duplicate = hotels(:stari_grad).kb_entries.build(title: "Breakfast times", content: "Different text.")

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:title], "has already been taken"
    end
  end

  # ...but not across hotels: every hotel has a "Breakfast", and one hotel
  # writing theirs down must never stop another from doing the same.
  test "two hotels may each have an entry with the same title" do
    with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).kb_entries.create!(title: "Breakfast", content: "07:00-10:30.") }

    with_tenant(hotels(:vrelo)) do
      entry = hotels(:vrelo).kb_entries.build(title: "Breakfast", content: "08:00-11:00.")

      assert entry.valid?, entry.errors.full_messages.to_sentence
    end
  end

  # Hotel#published_kb_entries is what the prompt builder reads. It is
  # asserted here — rather than only through the builder in Task 3 —
  # because it is the single point where "which entries may the model see"
  # is decided.
  test "Hotel#published_kb_entries returns only that hotel's published entries, in order" do
    stari_live, stari_draft = with_tenant(hotels(:stari_grad)) do
      [
        hotels(:stari_grad).kb_entries.create!(title: "Stari breakfast", content: "07:00.", published: true, position: 2),
        hotels(:stari_grad).kb_entries.create!(title: "Stari draft", content: "Unfinished.", position: 1)
      ]
    end
    vrelo_live = with_tenant(hotels(:vrelo)) do
      hotels(:vrelo).kb_entries.create!(title: "Vrelo breakfast", content: "08:00.", published: true)
    end

    with_tenant(hotels(:stari_grad)) do
      ids = hotels(:stari_grad).published_kb_entries.pluck(:id)

      assert_includes ids, stari_live.id
      assert_not_includes ids, stari_draft.id
      assert_not_includes ids, vrelo_live.id, "another hotel's knowledge must never be readable from here"
    end
  end
end
