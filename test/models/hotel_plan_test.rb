require "test_helper"

# What each of the three subscription plans buys, asserted against literal
# expectations rather than against Hotel::PLAN_FEATURES.
#
# That is the point of this file. A test that reads the same constant the app
# reads passes for any value of that constant — it proves the lookup works, not
# that Essentials is Q&A-only. These assertions are the spec written a second
# time, so editing PLAN_FEATURES turns them red.
class HotelPlanTest < ActiveSupport::TestCase
  test "essentials does not include service requests" do
    hotel = hotels(:stari_grad)
    hotel.update!(plan: :essentials)

    assert_not hotel.plan_allows?(:requests)
  end

  test "essentials does not include upselling" do
    hotel = hotels(:stari_grad)
    hotel.update!(plan: :essentials)

    assert_not hotel.plan_allows?(:upsell)
  end

  test "service includes service requests" do
    hotel = hotels(:stari_grad)
    hotel.update!(plan: :service)

    assert hotel.plan_allows?(:requests)
  end

  test "service does not include upselling" do
    hotel = hotels(:stari_grad)
    hotel.update!(plan: :service)

    assert_not hotel.plan_allows?(:upsell)
  end

  # Cumulative, not a separate island: a Revenue hotel is a Service hotel that
  # can also send offers, so it keeps every request feature.
  test "revenue includes both service requests and upselling" do
    hotel = hotels(:stari_grad)
    hotel.update!(plan: :revenue)

    assert hotel.plan_allows?(:requests)
    assert hotel.plan_allows?(:upsell)
  end

  test "a feature nobody sells is not allowed on any plan" do
    hotel = hotels(:stari_grad)

    Hotel.plans.each_key do |plan|
      hotel.update!(plan: plan)
      assert_not hotel.plan_allows?(:teleportation), "#{plan} allowed an invented feature"
    end
  end

  # The predicates are prefixed so `Hotel#service?` is never defined: on a model
  # that has_many :service_requests, an unprefixed `service?` reads as a question
  # about requests rather than about which plan was paid for.
  test "plan predicates are prefixed" do
    hotel = hotels(:stari_grad)
    hotel.update!(plan: :service)

    assert hotel.plan_service?
    assert_not hotel.respond_to?(:service?), "unprefixed Hotel#service? is ambiguous with service requests"
  end

  # Guards the migration's default, which is load-bearing well beyond this file:
  # eighteen tests across six files build a Hotel without naming a plan, and
  # every one of them assumes the full-featured product. If this flips to
  # essentials, they break for reasons unrelated to what they assert.
  test "a hotel created without a plan is on service" do
    hotel = Hotel.create!(name: "Hotel Bez Plana")

    assert_equal "service", hotel.plan
    assert hotel.plan_allows?(:requests)
  end
end
