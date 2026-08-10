require "test_helper"

# The banner is the only way the front desk learns that "a person will reply"
# now means them, for every guest. Its absence matters as much as its presence:
# a banner that is always there is wallpaper, and nobody reads wallpaper.
class StaffAiStatusNoticeTest < ActionView::TestCase
  include StaffHelper

  setup do
    @hotel = hotels(:stari_grad)
    Current.hotel = @hotel
    ActsAsTenant.current_tenant = @hotel

    # config.cache_store is :null_store in this environment, so a circuit
    # breaker on the default store can never be open and the branch below
    # would pass vacuously. Swapped for a real store, and restored in teardown.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
    Current.hotel = nil
  end

  test "says nothing while the assistant is working" do
    assert_nil staff_ai_status_notice
  end

  test "names the hotel's own switch when the assistant is off" do
    @hotel.update!(ai_enabled: false)

    assert_match(/switched off/i, staff_ai_status_notice)
  end

  test "says the assistant is paused when the breaker is open" do
    Ai::CircuitBreaker.new(@hotel).open!

    notice = staff_ai_status_notice

    assert_match(/paused/i, notice)
    assert_match(/manually/i, notice)
    assert_match(/resume on its own/i, notice, "a receptionist should know this is temporary")
  end

  test "says so when the hotel has spent today's budget" do
    @hotel.update!(ai_daily_token_budget: 1_000)
    AiRun.create!(hotel: @hotel, kind: :reply, status: :success, input_tokens: 950, output_tokens: 0)

    notice = staff_ai_status_notice

    assert_match(/usage limit/i, notice)
    assert_match(/translation are unaffected/i, notice,
                 "the lifeline between a guest and a receptionist keeps working, and staff need to know it")
  end

  # A hotel that has switched the assistant off does not also need to be told
  # its circuit breaker is open.
  test "only one thing is said at a time" do
    @hotel.update!(ai_enabled: false)
    Ai::CircuitBreaker.new(@hotel).open!

    assert_match(/switched off/i, staff_ai_status_notice)
  end

  test "another hotel's outage is not this hotel's banner" do
    Ai::CircuitBreaker.new(hotels(:vrelo)).open!

    assert_nil staff_ai_status_notice
  end
end
