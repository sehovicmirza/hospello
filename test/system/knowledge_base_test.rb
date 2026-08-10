require "application_system_test_case"

# Short, single-purpose tests with preconditions set up directly in Ruby —
# this suite's house rule (see test/system/guest_chat_test.rb).
class KnowledgeBaseTest < ApplicationSystemTestCase
  test "a hotel admin writes an entry and publishes it" do
    sign_in_as_hotel_admin

    click_on "Knowledge base"
    assert_text "This is what the assistant is allowed to tell your guests"

    click_on "Add an entry"
    fill_in "Title", with: "Room service"
    fill_in "What the assistant may tell guests", with: "Room service runs 07:00-23:00 — dial 9 from the room phone."
    click_on "Save entry"

    assert_text "“Room service” saved."

    # Scoped to this entry's own row: the fixtures carry other drafts, so an
    # unscoped click would be ambiguous — and, worse, could publish somebody
    # else's half-written entry.
    entry = ActsAsTenant.with_tenant(hotels(:stari_grad)) { KbEntry.find_by!(title: "Room service") }

    within "##{ActionView::RecordIdentifier.dom_id(entry)}" do
      # Saved without ticking the box means a draft — the guest-facing state
      # has to be asked for, never arrived at.
      assert_text "Draft"
      click_on "Publish"
    end

    assert_text "“Room service” is now live for guests."
    within("##{ActionView::RecordIdentifier.dom_id(entry)}") { assert_text "Live" }
    assert entry.reload.published?
  end

  test "the empty state offers a starter that opens the form already named" do
    ActsAsTenant.with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).kb_entries.destroy_all }
    sign_in_as_hotel_admin

    visit staff_kb_entries_path
    within("#kb-starters") { click_on "Wi-Fi" }

    assert_equal "Wi-Fi", find_field("Title").value
  end

  test "a receptionist can look things up but is not offered the editing controls" do
    ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      hotels(:stari_grad).kb_entries.create!(title: "Bicycle hire", content: "Bicycles at the front desk, 15 KM a day.")
    end

    visit root_url
    fill_in "email_address", with: users(:stari_staff).email_address
    fill_in "password", with: "password123"
    click_on "Sign in"
    assert_text "Signed in as #{users(:stari_staff).name}"

    visit staff_kb_entries_path

    assert_text "Bicycles at the front desk"
    assert_no_link "Add an entry"
    assert_no_button "Publish"
  end

  private
    def sign_in_as_hotel_admin
      visit root_url
      fill_in "email_address", with: users(:stari_admin).email_address
      fill_in "password", with: "password123"
      click_on "Sign in"
      # Assert on the destination, not the click (engineering rule 4).
      assert_text "Signed in as #{users(:stari_admin).name}"
    end
end
