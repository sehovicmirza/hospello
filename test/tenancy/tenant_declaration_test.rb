require "test_helper"

class TenantDeclarationTest < ActiveSupport::TestCase
  # Models exempt from acts_as_tenant, with the reason each is exempt.
  # Adding a model here is a deliberate security decision — justify it in the comment.
  EXEMPT = {
    "User"     => "hotel_id is nullable: platform admins belong to no hotel",
    "AuditLog" => "records platform-level actions that may have no hotel"
  }.freeze

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

  test "acts_as_tenant is configured to fail closed" do
    assert ActsAsTenant.configuration.require_tenant,
      "require_tenant must stay true: without it, a query written outside a tenant context " \
      "silently returns every hotel's rows instead of raising"
  end
end
