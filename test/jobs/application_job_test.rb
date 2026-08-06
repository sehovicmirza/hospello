require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  class TenantProbeJob < ApplicationJob
    class << self
      attr_accessor :tenant_during_perform
    end

    def perform(*)
      self.class.tenant_during_perform = ActsAsTenant.current_tenant
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
    TenantProbeJob.tenant_during_perform = nil
    CrossHotelProbeJob.tenant_during_perform = nil
  end

  test "a Hotel argument becomes the tenant for the whole perform" do
    TenantProbeJob.perform_now(hotels(:vrelo))

    assert_equal hotels(:vrelo), TenantProbeJob.tenant_during_perform
  end

  test "an argument that belongs to a hotel becomes the tenant" do
    TenantProbeJob.perform_now(HotelScopedRecord.new(hotels(:stari_grad)))

    assert_equal hotels(:stari_grad), TenantProbeJob.tenant_during_perform
  end

  test "a TenantFree job runs with no tenant" do
    CrossHotelProbeJob.perform_now("no hotel here")

    assert_nil CrossHotelProbeJob.tenant_during_perform
  end

  test "a job with no tenant argument refuses to run and names itself" do
    error = assert_raises(ActsAsTenant::Errors::NoTenantSet) do
      TenantProbeJob.perform_now("no hotel here")
    end

    assert_match "ApplicationJobTest::TenantProbeJob", error.message
    assert_nil TenantProbeJob.tenant_during_perform
  end

  test "the tenant does not leak past the perform" do
    TenantProbeJob.perform_now(hotels(:vrelo))

    assert_nil ActsAsTenant.current_tenant
  end
end
