require "test_helper"

# The knowledge base is what the Slice 3 concierge answers guests from, so
# the questions worth testing here are about who may change what a hotel
# tells its guests, and whether the act of putting text in front of guests
# leaves a trace.
#
# Cross-hotel isolation lives in test/tenancy/cross_tenant_access_test.rb,
# per this app's convention of keeping every tenant-boundary proof
# discoverable from that one file.
class Staff::KbEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    @admin = users(:stari_admin)
    @staff = users(:stari_staff)
  end

  test "the index lists this hotel's entries and marks the drafts" do
    live, draft = with_tenant(@hotel) do
      [
        @hotel.kb_entries.create!(title: "Breakfast times", content: "07:00-10:30.", published: true),
        @hotel.kb_entries.create!(title: "Spa plans", content: "Not decided yet.")
      ]
    end
    sign_in @admin

    get staff_kb_entries_path

    assert_response :success
    assert_select "##{dom_id(live)}" do
      assert_select "*", text: "Live"
    end
    assert_select "##{dom_id(draft)}" do
      assert_select "*", text: "Draft"
    end
  end

  test "the category filter narrows the list" do
    dining, transport = with_tenant(@hotel) do
      [
        @hotel.kb_entries.create!(title: "Breakfast", content: "07:00.", category: :dining),
        @hotel.kb_entries.create!(title: "Airport bus", content: "Every hour.", category: :transport)
      ]
    end
    sign_in @admin

    get staff_kb_entries_path(category: "dining")

    assert_response :success
    assert_select "##{dom_id(dining)}"
    assert_select "##{dom_id(transport)}", count: 0
  end

  # An unrecognised ?category= must fall back to "everything" rather than
  # reaching an enum or scope lookup with attacker-chosen input.
  test "an unknown category shows everything instead of erroring" do
    entry = with_tenant(@hotel) { @hotel.kb_entries.create!(title: "Anything", content: "x") }
    sign_in @admin

    get staff_kb_entries_path(category: "destroy_all")

    assert_response :success
    assert_select "##{dom_id(entry)}"
  end

  test "a hotel admin creates an entry, and it starts as a draft" do
    sign_in @admin

    assert_difference -> { with_tenant(@hotel) { KbEntry.count } }, 1 do
      post staff_kb_entries_path, params: { kb_entry: { title: "Check-out", content: "11:00.", category: "policies" } }
    end

    entry = with_tenant(@hotel) { KbEntry.find_by!(title: "Check-out") }
    assert_not entry.published?, "a newly created entry must not be live for guests unless asked for"
    assert_equal "policies", entry.category
  end

  test "publishing makes an entry live and writes an audit entry naming who did it" do
    entry = with_tenant(@hotel) { @hotel.kb_entries.create!(title: "Wi-Fi", content: "Password on the card.") }
    sign_in @admin

    assert_difference -> { AuditLog.where(action: "kb_entry.publish").count }, 1 do
      patch publish_staff_kb_entry_path(entry), params: { published: "true" }
    end

    assert entry.reload.published?
    log = AuditLog.where(action: "kb_entry.publish").last
    assert_equal @admin, log.actor_user
    assert_equal @hotel, log.hotel
    # Compared by type and id rather than by loading `log.target`: KbEntry
    # is tenant-scoped, so dereferencing the polymorphic association from
    # out here — where no tenant is set, as in any audit-log review screen —
    # raises rather than returning the row.
    assert_equal "KbEntry", log.target_type
    assert_equal entry.id, log.target_id
  end

  test "unpublishing takes an entry back out of guests' reach, and is audited too" do
    entry = with_tenant(@hotel) { @hotel.kb_entries.create!(title: "Old offer", content: "Expired.", published: true) }
    sign_in @admin

    assert_difference -> { AuditLog.where(action: "kb_entry.unpublish").count }, 1 do
      patch publish_staff_kb_entry_path(entry), params: { published: "false" }
    end

    assert_not entry.reload.published?
  end

  # A receptionist is answering the same questions by hand all day and has
  # to be able to look up what the hotel already promised...
  test "a plain staff member may read the knowledge base" do
    with_tenant(@hotel) { @hotel.kb_entries.create!(title: "Parking", content: "Garage under the building.") }
    sign_in @staff

    get staff_kb_entries_path

    assert_response :success
    assert_select "*", text: /Parking/
  end

  # ...but changing what the hotel promises is not a mid-shift decision.
  test "a plain staff member may not create, edit, publish or delete" do
    entry = with_tenant(@hotel) { @hotel.kb_entries.create!(title: "Parking", content: "Garage.") }
    sign_in @staff

    get new_staff_kb_entry_path
    assert_response :forbidden

    assert_no_difference -> { with_tenant(@hotel) { KbEntry.count } } do
      post staff_kb_entries_path, params: { kb_entry: { title: "Sneaky", content: "x" } }
    end
    assert_response :forbidden

    get edit_staff_kb_entry_path(entry)
    assert_response :forbidden

    patch publish_staff_kb_entry_path(entry), params: { published: "true" }
    assert_response :forbidden
    assert_not entry.reload.published?, "a receptionist must not be able to put text in front of guests"

    delete staff_kb_entry_path(entry)
    assert_response :forbidden
    assert with_tenant(@hotel) { KbEntry.exists?(entry.id) }
  end

  test "an over-long entry re-renders the form with the message rather than saving" do
    sign_in @admin

    assert_no_difference -> { with_tenant(@hotel) { KbEntry.count } } do
      post staff_kb_entries_path, params: { kb_entry: { title: "Too long", content: "a" * 2001 } }
    end

    assert_response :unprocessable_content
    assert_select "*", text: /split long topics into separate entries/
  end

  test "the empty state offers the topics guests actually ask about" do
    with_tenant(@hotel) { @hotel.kb_entries.destroy_all }
    sign_in @admin

    get staff_kb_entries_path

    assert_response :success
    assert_select "#kb-starters" do
      assert_select "*", text: "Breakfast"
      assert_select "*", text: "Wi-Fi"
      assert_select "*", text: "Check-out"
    end
  end
end
