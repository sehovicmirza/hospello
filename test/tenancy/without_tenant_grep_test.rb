require "test_helper"

class WithoutTenantGrepTest < ActiveSupport::TestCase
  # Every one of these defeats the acts_as_tenant default scope, so a query that
  # looks ordinary returns every hotel's rows. They are allowed ONLY in the
  # platform-admin namespace, where crossing tenants is the job — or, for
  # find_by_sql/raw connection SQL, in the one narrow file ALLOWLIST names
  # below (see that constant).
  ESCAPES = {
    /\bwithout_tenant\b/ => "ActsAsTenant.without_tenant drops the tenant scope for a block",
    /\bActsAsTenant\.unscoped\b/ => "ActsAsTenant.unscoped = true drops the tenant scope globally",
    /\.unscoped\b/ => "relation.unscoped drops the default scope, tenant condition included",
    /\bdefault_tenant\s*=/ => "ActsAsTenant.default_tenant = satisfies require_tenant everywhere, so nothing ever raises",
    # Review round 1, IMPORTANT 8: GuestSession.authenticate_by_token added a
    # find_by_sql call reasoned to be tenant-safe (it never touches AR's
    # default_scope machinery at all, so it needs no tenant and sets none —
    # see that method's own comment) — but ESCAPES had no pattern for it or
    # for the equivalent raw-connection methods, so that reasoning was a
    # one-off judgment call with no tripwire: a *different*, unreviewed
    # find_by_sql/raw SQL added anywhere else in app/ tomorrow would sail
    # through this test in total silence.
    /\bfind_by_sql\b/ => "find_by_sql builds records straight from a raw SQL row, bypassing the default_scope (and so the tenant check) entirely",
    /\.connection\.(execute|select_all|select_one|select_rows|select_value|exec_query)\b/ =>
      "raw SQL via ActiveRecord's connection object bypasses every model-level scope, tenant included"
  }.freeze

  ALLOWED_PREFIX = "app/controllers/platform/"

  # Named, narrow exceptions outside the platform namespace — each one is a
  # specific, reviewed decision, not a loophole for the whole file: only the
  # listed pattern(s) are exempted for that path, so a *different* escape
  # added to the same file (e.g. `.unscoped` sneaked into guest_session.rb)
  # still trips the test below.
  ALLOWLIST = {
    "app/models/guest_session.rb" => [ /\bfind_by_sql\b/ ]
  }.freeze

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

  test "tenant-scope escapes appear only in the platform controller namespace, or an explicitly reviewed allowlist entry" do
    offenders = scanned_sources.flat_map do |path, source|
      allowed_patterns = ALLOWLIST.fetch(path, [])

      ESCAPES.filter_map do |pattern, reason|
        next unless source.match?(pattern)
        next if allowed_patterns.include?(pattern)

        "#{path} — #{reason}"
      end
    end

    assert_empty offenders,
      "tenant-scope escapes found outside #{ALLOWED_PREFIX} with no allowlist entry:\n  #{offenders.join("\n  ")}"
  end

  # The allowlist above exempts guest_session.rb from the find_by_sql
  # pattern specifically — this pins that the exemption still matches
  # reality (the file really does use find_by_sql, so the entry isn't stale)
  # and, more importantly, that being allowlisted for find_by_sql does NOT
  # quietly exempt that same file from every *other* escape in ESCAPES.
  test "the guest_session.rb allowlist entry covers exactly find_by_sql, nothing broader" do
    source = File.read(Rails.root.join("app/models/guest_session.rb"))
    allowed_patterns = ALLOWLIST.fetch("app/models/guest_session.rb")

    assert source.match?(/\bfind_by_sql\b/),
      "guest_session.rb no longer uses find_by_sql — remove the now-stale allowlist entry"

    (ESCAPES.keys - allowed_patterns).each do |pattern|
      assert_not source.match?(pattern),
        "guest_session.rb now trips #{pattern.inspect}, which is not covered by its allowlist entry — " \
        "this needs the same review any other new escape would, not a silent pass"
    end
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
