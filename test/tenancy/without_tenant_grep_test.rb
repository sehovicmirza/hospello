require "test_helper"

class WithoutTenantGrepTest < ActiveSupport::TestCase
  # ActsAsTenant.without_tenant disables the tenant scope entirely. It is allowed
  # ONLY in the platform-admin namespace, where crossing tenants is the job.
  ALLOWED_PREFIX = "app/controllers/platform/"

  test "without_tenant appears only in the platform controller namespace" do
    offenders = Dir.glob(Rails.root.join("app/**/*.rb")).filter_map do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if rel.start_with?(ALLOWED_PREFIX)
      rel if File.read(path).include?("without_tenant")
    end

    assert_empty offenders,
      "ActsAsTenant.without_tenant found outside #{ALLOWED_PREFIX}: #{offenders.join(', ')}"
  end
end
