require "test_helper"

class WithoutTenantGrepTest < ActiveSupport::TestCase
  # Every one of these defeats the acts_as_tenant default scope, so a query that
  # looks ordinary returns every hotel's rows. They are allowed ONLY in the
  # platform-admin namespace, where crossing tenants is the job.
  ESCAPES = {
    /\bwithout_tenant\b/ => "ActsAsTenant.without_tenant drops the tenant scope for a block",
    /\bActsAsTenant\.unscoped\b/ => "ActsAsTenant.unscoped = true drops the tenant scope globally",
    /\.unscoped\b/ => "relation.unscoped drops the default scope, tenant condition included",
    /\bdefault_tenant\s*=/ => "ActsAsTenant.default_tenant = satisfies require_tenant everywhere, so nothing ever raises"
  }.freeze

  ALLOWED_PREFIX = "app/controllers/platform/"

  # config/ is scanned as well as the reviewed app/lib/db set: an initializer is
  # the most natural place to reach for default_tenant, and it is the one place
  # where a single line disables the fail-closed guarantee for the whole app.
  SCANNED_GLOBS = %w[
    app/**/*.rb
    lib/**/*.rb
    lib/tasks/**/*.rake
    db/**/*.rb
    config/**/*.rb
  ].freeze

  test "tenant-scope escapes appear only in the platform controller namespace" do
    offenders = scanned_sources.flat_map do |path, source|
      ESCAPES.filter_map { |pattern, reason| "#{path} — #{reason}" if source.match?(pattern) }
    end

    assert_empty offenders,
      "tenant-scope escapes found outside #{ALLOWED_PREFIX}:\n  #{offenders.join("\n  ")}"
  end

  private
    def scanned_sources
      SCANNED_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }.uniq.filter_map do |path|
        relative_path = Pathname.new(path).relative_path_from(Rails.root).to_s
        next if relative_path.start_with?(ALLOWED_PREFIX)

        [ relative_path, File.read(path) ]
      end
    end
end
