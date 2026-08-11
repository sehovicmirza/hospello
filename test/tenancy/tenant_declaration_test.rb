require "test_helper"

class TenantDeclarationTest < ActiveSupport::TestCase
  # Models exempt from acts_as_tenant, with the reason each is exempt.
  # Adding a model here is a deliberate security decision — justify it in the comment.
  #
  # An exemption is not a free pass: inside a hotel context these models are the
  # only ones whose bare relations cross hotels, so each names the access paths
  # that are allowed there.
  EXEMPT = {
    "User"     => "hotel_id is nullable: platform admins belong to no hotel. " \
                  "In a hotel context read users only via Current.hotel.users or " \
                  "User.for_hotel(hotel) — User.all crosses hotels and will not raise.",
    "AuditLog" => "records platform-level actions that may have no hotel. " \
                  "In a hotel context read entries only via AuditLog.for_hotel(hotel) — " \
                  "AuditLog.all crosses hotels and will not raise.",
    "WebhookEvent" => "written by Webhooks::WhatsappController before any tenant can possibly be " \
                  "known — hotel_id is nil until Slice 6 Task 3's Whatsapp::InboundRouter resolves " \
                  "one, and that resolution has to read this very row to do its job, so " \
                  "acts_as_tenant's require_tenant guard would make the lookup impossible, not just " \
                  "inconvenient. Not guest- or staff-facing data: it is an operational record of the " \
                  "webhook boundary itself, read by id (Whatsapp::ProcessInboundJob) rather than " \
                  "through any hotel-scoped listing, so no WebhookEvent.for_hotel scope exists — add " \
                  "one the day something actually needs to list a hotel's webhook history."
  }.freeze

  # A throwaway tenant-scoped model over an existing table, so the fail-closed
  # guarantee is asserted as behaviour rather than as the value of a config flag
  # set two files away.
  class TenantProbe < ApplicationRecord
    self.table_name = "users"

    include TenantScoped
  end

  test "every model with a hotel_id column declares acts_as_tenant" do
    Rails.application.eager_load!

    offenders = ApplicationRecord.descendants.reject(&:abstract_class?).filter_map do |model|
      next unless model.column_names.include?("hotel_id")
      next if EXEMPT.key?(model.name)
      model.name unless model.respond_to?(:scoped_by_tenant?) && model.scoped_by_tenant?
    end

    assert_empty offenders,
      "these models have hotel_id but do not declare acts_as_tenant (include TenantScoped): #{offenders.join(', ')}"
  end

  test "a tenant-scoped query outside a tenant context raises instead of returning every hotel's rows" do
    assert_nil ActsAsTenant.current_tenant, "precondition: no tenant is set"

    assert_raises(ActsAsTenant::Errors::NoTenantSet) { TenantProbe.count }
    assert_raises(ActsAsTenant::Errors::NoTenantSet) { TenantProbe.first }
  end

  test "a tenant-scoped query inside a tenant context sees only that hotel's rows" do
    with_tenant(hotels(:stari_grad)) do
      assert_equal hotels(:stari_grad).users.count, TenantProbe.count
    end

    with_tenant(hotels(:vrelo)) do
      assert_equal hotels(:vrelo).users.count, TenantProbe.count
    end
  end

  test "the exempt models offer a scope for reading one hotel's rows" do
    assert_equal hotels(:stari_grad).users.sort, User.for_hotel(hotels(:stari_grad)).sort

    AuditLog.record!(actor: users(:platform), hotel: hotels(:vrelo), action: "hotel.suspended")

    assert_equal [ hotels(:vrelo) ], AuditLog.for_hotel(hotels(:vrelo)).map(&:hotel)
    assert_empty AuditLog.for_hotel(hotels(:stari_grad))
  end
end
