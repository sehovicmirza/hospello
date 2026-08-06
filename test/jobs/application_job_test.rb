require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  # Records the tenant of every perform, so a test can tell "ran with no tenant"
  # apart from "never ran".
  class TenantProbeJob < ApplicationJob
    class << self
      attr_accessor :tenants_seen
    end

    def perform(*, **)
      self.class.tenants_seen << ActsAsTenant.current_tenant
    end
  end

  class CrossHotelProbeJob < TenantProbeJob
    include TenantFree
  end

  # Stands in for the hotel-scoped records later tasks will hand to jobs.
  HotelScopedRecord = Struct.new(:hotel) do
    def hotel_id = hotel.id
  end

  setup do
    TenantProbeJob.tenants_seen = []
    CrossHotelProbeJob.tenants_seen = []
  end

  test "a Hotel argument becomes the tenant for the whole perform" do
    TenantProbeJob.perform_now(hotels(:vrelo))

    assert_equal [ hotels(:vrelo) ], TenantProbeJob.tenants_seen
  end

  test "a Hotel passed as a keyword argument becomes the tenant" do
    TenantProbeJob.perform_now(hotel: hotels(:vrelo))

    assert_equal [ hotels(:vrelo) ], TenantProbeJob.tenants_seen
  end

  test "an argument that belongs to a hotel becomes the tenant" do
    TenantProbeJob.perform_now(HotelScopedRecord.new(hotels(:stari_grad)))

    assert_equal [ hotels(:stari_grad) ], TenantProbeJob.tenants_seen
  end

  test "a TenantFree job runs with no tenant" do
    CrossHotelProbeJob.perform_now("no hotel here")

    assert_equal [ nil ], CrossHotelProbeJob.tenants_seen
  end

  # acts_as_tenant serializes the enqueue-time tenant into the job and restores it
  # in deserialize. A TenantFree job must not inherit it: it iterates hotels
  # itself, and an ambient tenant would silently narrow every query it makes to
  # whichever hotel happened to enqueue it.
  test "a TenantFree job does not inherit the tenant it was enqueued under" do
    payload = ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      CrossHotelProbeJob.new("no hotel here").serialize
    end

    assert_equal hotels(:stari_grad).to_global_id.to_s, payload["current_tenant"],
      "precondition: acts_as_tenant should have captured the enqueue-time tenant"

    ActiveJob::Base.execute(payload)

    assert_equal [ nil ], CrossHotelProbeJob.tenants_seen
  end

  test "a job with no tenant argument refuses to run and names itself" do
    error = assert_raises(ActsAsTenant::Errors::NoTenantSet) do
      TenantProbeJob.perform_now("no hotel here")
    end

    assert_match "ApplicationJobTest::TenantProbeJob", error.message
    assert_empty TenantProbeJob.tenants_seen
  end

  test "the tenant does not leak past the perform" do
    TenantProbeJob.perform_now(hotels(:vrelo))

    assert_nil ActsAsTenant.current_tenant
  end
end
