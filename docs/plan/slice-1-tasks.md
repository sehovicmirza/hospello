# Slice 1 — Foundation, tenancy, hotel setup

Demo at end of slice: a platform admin creates two differently-branded hotels, creates each hotel's
first admin, and that hotel admin configures branding, rooms, departments, categories, and staff,
then downloads the hotel's reusable QR code and printable instruction sheet. Hotel A's staff cannot
see any of hotel B's data — proven by an automated isolation suite.

Repo state at slice start: freshly scaffolded Rails 8.0.5.1 app (commit `dbd62d7`) with Postgres,
Solid Queue/Cache/Cable, Hotwire (importmap + Turbo + Stimulus), Propshaft, Tailwind v4.
Gems already in the Gemfile and installed: `acts_as_tenant`, `pundit`, `anthropic`, `rqrcode`,
`rack-attack`, `phonelib`, `image_processing`, `aws-sdk-s3`, `rails-i18n`, `sentry-ruby`,
`sentry-rails`, `lograge`, `mission_control-jobs`, `bcrypt`, plus `webmock`/`capybara`/
`selenium-webdriver`/`dotenv-rails`/`bundler-audit` in dev/test. `config/database.yml` already points
primary + cache + queue + cable at one database. No app code, models, or migrations exist yet.

Test framework: **Minitest + fixtures** (Rails default). No RSpec, no FactoryBot.
Run tests with `bin/rails test` and `bin/rails test:system`.

## House rules learned the hard way — they bind every task in every slice

**Write assertions that can fail.** Six findings across Tasks 1 and 2 were tests that passed
regardless of the behaviour under test. The recurring shapes:
- `assert_match "2", response.body` — substring matching against a whole page. Every digit and most
  short words appear somewhere in Tailwind class names. Scope to a row (`within`, `assert_select`).
- Asserting a value that equals the column default, so the test passes even if the attribute was
  never assigned. Invert the default in the test data.
- Asserting on a variable that a `setup` block already set to the expected value.
For anything guarding a security or tenancy boundary, **break the code, watch the test fail, put it
back**. A test that cannot fail is worse than no test, because it advertises coverage that isn't there.

**Assert on the destination after a click that navigates.** `click_on` returns when the click is
dispatched, not when the resulting page has loaded. `click_on "Sign in"` followed by `visit`
somewhere raced the sign-in response and left the session cookie unset, which surfaced much later as
a missing form field. One `assert_text` on the destination makes the click and its navigation a
single step.

**System tests: keep each one short and single-purpose.** Chrome does not release the input grab a
native `<select>` popup takes when the page navigates while that popup is open, and Rails reuses one
browser process across the whole run, so a poisoned session breaks whichever test runs next. The
harness now blurs after `select` and ends the browser between tests
(`test/application_system_test_case.rb`) — don't remove either. Still, prefer several focused tests
over one long ceremony: set preconditions up directly and drive only the behaviour under test
through the browser.

**Don't add a workaround for a failure you haven't diagnosed.** Two wrong theories (Turbo, then a
selenium version mismatch) produced five permanent changes across the harness and three views,
including a production behaviour change, none of which addressed the real cause. If a test fails for
a reason you can't explain, say so in your report rather than sprinkling mitigations.

**Copy the spec demands needs a test, and the test must not read the same file the app reads.**
Added after Slice 2 Task 1, where nine guest-facing requirements — the emergency-channel notice, the
privacy notice and its pending-legal-review marker, the `powered_by_visible` toggle, Accept-Language
preselection, and the entire Arabic locale file — could each be deleted outright with the full suite
staying green. Two traps to avoid, both of which produced a passing test over broken code here:
- **Fallbacks absorb the failure.** With `config.i18n.fallbacks = true`, emptying a locale file
  renders English and nothing notices. Read locale files **off disk** and compare key sets and
  `%{interpolation}` variables structurally between languages, rather than going through `I18n.t`.
- **Deriving the expected value from the source under test is circular.** Asserting
  `assert_text I18n.t("guest.emergency_notice")` passes no matter what that key contains, including
  nothing. Paste the literal string into the test.
For direction-aware layout, asserting `dir="rtl"` is present is **not** a claim that anything reads
right-to-left — that exact mistake shipped twice. Pin the logical utility class against its physical
counterpart (`test/controllers/staff/qr_codes_controller_test.rb`) and measure real geometry with
`getBoundingClientRect` (`test/system/qr_download_test.rb`).

---

### Task 1: Tenancy foundation, authentication, and the isolation test suite

**Why this task exists:** every later task depends on `Current.hotel` being set correctly and on
unscoped queries failing loudly. The isolation suite written here is the gate every subsequent task
must keep green.

**Files:**
- Create: `db/migrate/*_create_hotels.rb`, `db/migrate/*_create_users.rb`, `db/migrate/*_create_sessions.rb`, `db/migrate/*_create_audit_logs.rb`
- Create: `app/models/hotel.rb`, `app/models/user.rb`, `app/models/session.rb`, `app/models/audit_log.rb`, `app/models/current.rb`, `app/models/application_record.rb` (already exists — modify)
- Create: `app/models/concerns/tenant_scoped.rb`
- Create: `app/controllers/concerns/authentication.rb`
- Create: `app/controllers/application_controller.rb` (exists — modify)
- Create: `app/controllers/staff/base_controller.rb`, `app/controllers/platform/base_controller.rb`
- Create: `app/controllers/sessions_controller.rb`, `app/views/sessions/new.html.erb`
- Create: `app/policies/application_policy.rb`
- Create: `app/jobs/application_job.rb` (exists — modify), `app/jobs/concerns/tenant_free.rb`
- Create: `config/initializers/acts_as_tenant.rb`, `config/initializers/pundit.rb` (if needed)
- Create: `test/models/hotel_test.rb`, `test/models/user_test.rb`
- Create: `test/tenancy/tenant_declaration_test.rb`, `test/tenancy/without_tenant_grep_test.rb`
- Create: `test/fixtures/hotels.yml`, `test/fixtures/users.yml`
- Create: `test/test_helper.rb` (exists — modify)
- Modify: `config/routes.rb`

**Interfaces produced (later tasks rely on these exact names):**
- `Current.user`, `Current.hotel`, `Current.session` (ActiveSupport::CurrentAttributes)
- `Hotel` columns as specified below; `Hotel#active?`, `Hotel#suspended?`
- `User#role` enum values `staff`, `hotel_admin`, `platform_admin`; `User#platform_admin?` etc.
- `TenantScoped` concern — `include TenantScoped` declares `acts_as_tenant(:hotel)` and the
  `belongs_to :hotel` association in one line; every tenant model uses it.
- `Staff::BaseController` — authenticates a staff/hotel_admin user, sets `Current.hotel` and
  `ActsAsTenant.current_tenant` from `Current.user.hotel`, refuses platform admins.
- `Platform::BaseController` — authenticates a platform_admin user, sets **no** ambient tenant,
  provides `audit!(action, target: nil, **metadata)` which writes an `AuditLog` row.
- `AuditLog.record!(actor:, hotel:, action:, target: nil, metadata: {})`
- `TenantFree` marker module for jobs that legitimately run without a tenant.

**Schema for this task (exact columns):**

`hotels`:
- `name` string null: false
- `slug` string null: false, unique index
- `timezone` string null: false, default "Europe/Sarajevo"
- `staff_locale` string null: false, default "en"
- `status` integer null: false, default 0  (enum: active: 0, suspended: 1)
- `primary_color` string null: false, default "#1F3A5F"
- `secondary_color` string null: false, default "#C9A227"
- `concierge_name` string
- `welcome_message` text
- `contact_phone` string
- `contact_notes` text
- `checkout_time` string   (e.g. "11:00" — a display string, not a Time)
- `escalation_email` string
- `powered_by_visible` boolean null: false, default true
- `ai_enabled` boolean null: false, default true
- `ai_daily_token_budget` integer null: false, default 500_000
- `overdue_after_minutes` integer null: false, default 120
- `settings` jsonb null: false, default {}
- timestamps

`users`:
- `hotel_id` bigint, FK to hotels, **nullable** (null only for platform_admin)
- `email_address` string null: false, unique index (store downcased/stripped)
- `password_digest` string null: false
- `name` string null: false
- `role` integer null: false, default 0  (enum: staff: 0, hotel_admin: 1, platform_admin: 2)
- `locale` string null: false, default "en"
- `active` boolean null: false, default true
- timestamps
- index `[hotel_id, role]`

`sessions` (Rails 8 auth generator shape):
- `user_id` bigint null: false, FK
- `token` string null: false, unique index
- `ip_address` string
- `user_agent` string
- timestamps

`audit_logs`:
- `actor_user_id` bigint FK to users, nullable
- `hotel_id` bigint FK to hotels, nullable  (**not** tenant-scoped — platform actions may have no hotel)
- `action` string null: false
- `target_type` string, `target_id` bigint
- `metadata` jsonb null: false, default {}
- `created_at` datetime null: false (use `t.datetime :created_at` — no updated_at)
- index `[hotel_id, created_at]`

- [ ] **Step 1: Generate the Rails 8 authentication scaffold, then adapt it**

Run `bin/rails generate authentication`. This creates `app/models/user.rb`, `app/models/session.rb`,
`app/models/current.rb`, `app/controllers/concerns/authentication.rb`, `app/controllers/sessions_controller.rb`,
`app/controllers/passwords_controller.rb`, mailer + views, and a migration. Then:
- Delete the generated `PasswordsController`, its views, and `PasswordsMailer` — password reset is
  out of scope for the MVP (staff accounts are created by admins). Remove their routes.
- Rewrite the generated migration into the two migrations specified above (`create_users`,
  `create_sessions`) with the exact columns listed, and add `create_hotels` **before** them so the
  FK resolves. Add `create_audit_logs` last.
- Extend `Current` with `hotel` and keep the generated `session` / `user` accessors.

- [ ] **Step 2: Write the failing tenancy-declaration test**

```ruby
# test/tenancy/tenant_declaration_test.rb
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
end
```

- [ ] **Step 3: Run it to verify it fails**

`bin/rails test test/tenancy/tenant_declaration_test.rb` — expect failure (no models exist yet).

- [ ] **Step 4: Write the `without_tenant` grep test**

```ruby
# test/tenancy/without_tenant_grep_test.rb
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
```

- [ ] **Step 5: Implement the models, concern, and initializer**

`config/initializers/acts_as_tenant.rb`:
```ruby
ActsAsTenant.configure do |config|
  # Fail closed: a query on a tenant-scoped model outside a tenant context raises
  # instead of silently returning every hotel's rows.
  config.require_tenant = true
end
```

`app/models/concerns/tenant_scoped.rb`:
```ruby
# Every model whose rows belong to exactly one hotel includes this.
# It declares the association and the acts_as_tenant scope together so the two
# can never drift apart.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    acts_as_tenant :hotel
  end
end
```

`app/models/hotel.rb` — enum `status: { active: 0, suspended: 1 }`, `has_many :users, dependent: :destroy`,
validations: name presence, slug presence + uniqueness + format `/\A[a-z0-9][a-z0-9-]*\z/`,
timezone must be in `ActiveSupport::TimeZone::MAPPING.values` or a valid TZInfo identifier,
`staff_locale` inclusion in `%w[bs en]`, colors match `/\A#\h{6}\z/`.
Add `before_validation :normalize_slug` (downcase, strip, spaces → hyphens) when slug is blank,
deriving it from the name via `name.parameterize`.

`app/models/user.rb` — keeps the generator's `has_secure_password` and
`normalizes :email_address, with: ->(e) { e.strip.downcase }`. Add:
- `belongs_to :hotel, optional: true`
- `enum :role, { staff: 0, hotel_admin: 1, platform_admin: 2 }`
- validation: `platform_admin?` ⇒ `hotel_id` must be nil; otherwise `hotel_id` must be present.
  Write it as a custom validation with a clear message, e.g. "platform admins must not belong to a hotel".
- `scope :active, -> { where(active: true) }`
- Do **not** include `TenantScoped` (see EXEMPT above).

`app/models/audit_log.rb`:
```ruby
class AuditLog < ApplicationRecord
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :hotel, optional: true
  belongs_to :target, polymorphic: true, optional: true

  validates :action, presence: true

  def self.record!(actor:, action:, hotel: nil, target: nil, metadata: {})
    create!(actor_user: actor, hotel: hotel, action: action, target: target, metadata: metadata)
  end
end
```

- [ ] **Step 6: Implement the controllers**

`app/controllers/application_controller.rb`: include `Authentication` and `Pundit::Authorization`;
`rescue_from Pundit::NotAuthorizedError` with a 403 (render a plain "Not authorized" page);
`rescue_from ActiveRecord::RecordNotFound` with 404. Set `Current.session`/`Current.user` via the
generated Authentication concern.

`app/controllers/staff/base_controller.rb`:
```ruby
module Staff
  class BaseController < ApplicationController
    before_action :require_staff_user
    around_action :scope_to_current_hotel

    private
      def require_staff_user
        return head :forbidden if Current.user.nil? || Current.user.platform_admin?
        head :forbidden unless Current.user.active? && Current.user.hotel&.active?
      end

      def scope_to_current_hotel(&block)
        Current.hotel = Current.user.hotel
        ActsAsTenant.with_tenant(Current.user.hotel, &block)
      end
  end
end
```

`app/controllers/platform/base_controller.rb`: `before_action` requiring `Current.user&.platform_admin?`
(else `head :forbidden`); no ambient tenant; a protected
`audit!(action, target: nil, hotel: nil, **metadata)` helper delegating to `AuditLog.record!` with
`actor: Current.user`.

`app/jobs/application_job.rb` — an `around_perform` that finds the first argument responding to
`hotel_id` (or a `Hotel`) and wraps the perform in `ActsAsTenant.with_tenant(...)`; a job class that
includes `TenantFree` skips the hook; a job with neither raises a clear error naming the job class.
`app/jobs/concerns/tenant_free.rb` is an empty marker module with a comment explaining when it is
legitimate (cross-hotel maintenance jobs that iterate hotels themselves).

Routes: `root "sessions#new"` for now, plus `resource :session, only: %i[new create destroy]`, and
empty `namespace :staff` / `namespace :platform` blocks that later tasks fill in.
Add `get "up" => "rails/health#show", as: :rails_health_check` (already present in generated routes —
keep it).

- [ ] **Step 7: Write fixtures and model tests**

`test/fixtures/hotels.yml` — two hotels with **different** branding, used by every isolation test in
the project:
```yaml
stari_grad:
  name: Hotel Stari Grad
  slug: stari-grad
  timezone: Europe/Sarajevo
  staff_locale: bs
  primary_color: "#1F3A5F"
  secondary_color: "#C9A227"
  concierge_name: Amila
  welcome_message: Dobrodošli u Hotel Stari Grad!
  contact_phone: "+387 33 000 000"

vrelo:
  name: Hotel Vrelo Bosne
  slug: vrelo-bosne
  timezone: Europe/Sarajevo
  staff_locale: en
  primary_color: "#0B6E4F"
  secondary_color: "#F2C14E"
  concierge_name: Emir
  welcome_message: Welcome to Hotel Vrelo Bosne!
  contact_phone: "+387 33 111 111"
```

`test/fixtures/users.yml` — one hotel_admin and one staff per hotel, plus one platform admin.
Use `password_digest: <%= BCrypt::Password.create("password123", cost: 4) %>`.
Name them `stari_admin`, `stari_staff`, `vrelo_admin`, `vrelo_staff`, `platform`.

`test/models/hotel_test.rb` — slug uniqueness, slug auto-derivation from name, colour format
validation, staff_locale inclusion, `active?`/`suspended?`.

`test/models/user_test.rb` — email normalization; platform_admin must have no hotel (assert invalid
with a hotel); staff/hotel_admin must have a hotel (assert invalid without one); role enum predicates.

Add to `test/test_helper.rb`: `WebMock.disable_net_connect!(allow_localhost: true)` (require
`webmock/minitest`), and a helper module for tests that need a tenant:
```ruby
module TenantTestHelper
  def with_tenant(hotel, &block) = ActsAsTenant.with_tenant(hotel, &block)
end
```
`ActiveSupport::TestCase` includes it. Because `require_tenant = true` is global, add
`ActsAsTenant.test_tenant = nil` handling as needed so model tests that legitimately touch
non-tenant models (User, Hotel, AuditLog) still work.

- [ ] **Step 8: Write the login system test**

`test/system/authentication_test.rb` — a staff user signs in with email + password and lands
somewhere authenticated; a wrong password shows an error and does not sign in; a suspended hotel's
staff user is refused.

- [ ] **Step 9: Run the full suite**

`bin/rails test` and `bin/rails test:system` — everything green, including both tenancy tests.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: tenancy foundation, authentication, and isolation test suite"
```

---

### Task 2: Platform admin namespace — hotels and first hotel admins

**Why this task exists:** acceptance scenario 1 ("a platform administrator creates two hotels with
different branding and information, and their data remains fully isolated") starts here.

**Files:**
- Create: `app/controllers/platform/hotels_controller.rb`, `app/controllers/platform/hotel_admins_controller.rb`
- Create: `app/views/platform/hotels/{index,new,edit,show}.html.erb`, `app/views/platform/hotel_admins/new.html.erb`
- Create: `app/views/layouts/platform.html.erb`
- Create: `app/policies/hotel_policy.rb`
- Create: `test/controllers/platform/hotels_controller_test.rb`, `test/controllers/platform/hotel_admins_controller_test.rb`
- Create: `test/system/platform_hotel_management_test.rb`
- Modify: `config/routes.rb`

**Interfaces consumed:** `Platform::BaseController` (with `audit!`), `Hotel`, `User`, `AuditLog` from Task 1.

**Interfaces produced:** routes `platform_hotels_path`, `platform_hotel_path(hotel)`,
`new_platform_hotel_hotel_admin_path(hotel)`; `Platform::BaseController#audit!` usage pattern.

- [ ] **Step 1: Write failing controller tests**

`test/controllers/platform/hotels_controller_test.rb` must cover:
- a platform admin can list, create, edit, suspend, and reactivate hotels
- a hotel_admin user gets 403 on every platform route (loop over the routes)
- a signed-out user is redirected to sign-in
- creating a hotel writes an `AuditLog` row with action `"hotel.create"`
- suspending writes `"hotel.suspend"`, reactivating writes `"hotel.activate"`

```ruby
test "hotel admin cannot reach any platform route" do
  sign_in users(:stari_admin)
  [platform_hotels_path, new_platform_hotel_path, platform_hotel_path(hotels(:vrelo))].each do |path|
    get path
    assert_response :forbidden, "expected 403 for #{path}"
  end
end
```
(Write a `sign_in(user)` test helper in `test/test_helper.rb` that posts to the session route, or sets
the session cookie directly — whichever matches the Rails 8 auth generator's shape.)

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement `Platform::HotelsController`**

Actions: `index`, `new`, `create`, `show`, `edit`, `update`, plus member `suspend` and `activate`
(PATCH). Every mutating action calls `audit!`. `index` lists hotels with their status, room count,
staff count, and whether a first admin exists — it is the platform admin's onboarding cockpit.
`show` displays the hotel's readiness at a glance and links to "Create first admin".

Strong params: `name`, `slug`, `timezone`, `staff_locale`, `powered_by_visible`, `ai_enabled`,
`ai_daily_token_budget`, `escalation_email`. Branding fields are the *hotel admin's* job (Task 3) —
the platform admin sets identity and platform-level switches only. `powered_by_visible` is
**platform-admin-only** and must not appear in any staff-side form.

Because hotels are not tenant-scoped rows themselves, no `without_tenant` is needed for listing.
Any query that touches tenant-scoped data (e.g. counting a hotel's rooms in a later task) must be
wrapped in `ActsAsTenant.with_tenant(hotel) { ... }`.

- [ ] **Step 4: Implement `Platform::HotelAdminsController#new/#create`**

Creates the hotel's **first** administrator: `User` with `role: :hotel_admin`, that hotel, a name, an
email, and a password the platform admin types (there is no email delivery in this slice — the
platform admin hands over the credentials during assisted onboarding, and the flash confirms this).
Writes `audit!("hotel_admin.create", target: user, hotel: hotel)`.
Validate that the email is unique platform-wide with a clear error.

- [ ] **Step 5: Views**

`app/views/layouts/platform.html.erb` — Hospello-branded chrome (this is the platform surface, so the
Hospello brand is correct here), a nav with "Hotels", and the signed-in admin's name + sign out.
Tailwind, calm and simple. Realistic empty state on `index` ("No hotels yet — create the first one").

- [ ] **Step 6: System test**

`test/system/platform_hotel_management_test.rb` — a platform admin signs in, creates two hotels with
different names/slugs, creates a first admin for one, suspends the other, and sees both states
reflected in the list.

- [ ] **Step 7: Run the full suite, then commit**

---

### Task 3: Staff namespace, hotel profile and branding

**Why this task exists:** the hotel's brand is the guest's whole experience; this is where the hotel
admin owns it. Also establishes the staff layout every later staff screen extends.

**Files:**
- Create: `app/controllers/staff/dashboard_controller.rb`, `app/controllers/staff/hotel_settings_controller.rb`
- Create: `app/views/layouts/staff.html.erb`, `app/views/staff/dashboard/show.html.erb`, `app/views/staff/hotel_settings/edit.html.erb`
- Create: `app/policies/hotel_settings_policy.rb` (or reuse `HotelPolicy` with an `update?` rule)
- Create: `app/helpers/branding_helper.rb`
- Create: `test/controllers/staff/hotel_settings_controller_test.rb`
- Create: `test/system/hotel_branding_test.rb`
- Modify: `config/routes.rb`, `app/models/hotel.rb` (Active Storage attachments)

**Interfaces consumed:** `Staff::BaseController`, `Hotel`, Pundit from Tasks 1–2.

**Interfaces produced:**
- `BrandingHelper#hotel_brand_style(hotel)` → an HTML-safe `style` attribute string defining the CSS
  custom properties `--brand-primary`, `--brand-secondary`, `--brand-on-primary`. Guest views in
  Slice 2 use exactly this helper, so its output must be usable on a `<body>` tag.
- `hotel.logo` and `hotel.welcome_image` Active Storage attachments.
- Route `edit_staff_hotel_settings_path`, `staff_root_path` (the dashboard).

- [ ] **Step 1: Attach images and configure Active Storage**

`app/models/hotel.rb`: `has_one_attached :logo`, `has_one_attached :welcome_image`. Validate content
type (`image/png`, `image/jpeg`, `image/webp`, `image/svg+xml` for the logo) and size (logo ≤ 2 MB,
welcome image ≤ 5 MB) with a plain custom validation — do not add a validation gem.

`config/storage.yml`: keep `local`/`test`, and add an `r2` service:
```yaml
r2:
  service: S3
  access_key_id: <%= ENV["R2_ACCESS_KEY_ID"] %>
  secret_access_key: <%= ENV["R2_SECRET_ACCESS_KEY"] %>
  endpoint: <%= ENV["R2_ENDPOINT"] %>
  bucket: <%= ENV["R2_BUCKET"] %>
  region: auto
  force_path_style: true
```
`config/environments/production.rb`: `config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "r2").to_sym`
so a pilot can fall back to `local` by env var without a code change.

- [ ] **Step 2: Write the failing branding-helper test**

```ruby
# test/helpers/branding_helper_test.rb
require "test_helper"

class BrandingHelperTest < ActionView::TestCase
  include BrandingHelper

  test "emits CSS custom properties for the hotel's colors" do
    style = hotel_brand_style(hotels(:stari_grad))
    assert_includes style, "--brand-primary:#1F3A5F"
    assert_includes style, "--brand-secondary:#C9A227"
  end

  test "picks a readable on-primary color for a light brand color" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = "#FFFFFF"
    assert_includes hotel_brand_style(hotel), "--brand-on-primary:#111827"
  end

  test "picks a readable on-primary color for a dark brand color" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = "#000000"
    assert_includes hotel_brand_style(hotel), "--brand-on-primary:#FFFFFF"
  end
end
```
Implement `hotel_brand_style` using relative luminance (WCAG formula) to choose the on-primary color
— a hotel that picks a pale brand color must not get white-on-white guest text. This is an
accessibility requirement, not a nicety.

- [ ] **Step 3: Implement the staff layout**

`app/views/layouts/staff.html.erb` — Hospello-branded operational chrome (staff dashboard uses the
Hospello brand consistently, per the spec). Sidebar/nav with the sections this slice creates
(Dashboard, Hotel settings, Rooms, Departments & categories, Staff, QR code) — later slices add
Conversations, Requests, Knowledge base, Analytics. Show the hotel name and the signed-in user.
Desktop/tablet first, usable on mobile (collapsing nav is fine; keep it simple).
Timestamps rendered anywhere in staff views must use the hotel's timezone — add a helper
`staff_time(t)` that formats `t.in_time_zone(Current.hotel.timezone)`.

- [ ] **Step 4: Implement `Staff::HotelSettingsController` (`edit`/`update`)**

Editable here: `name`, `timezone`, `staff_locale`, `primary_color`, `secondary_color`,
`concierge_name`, `welcome_message`, `contact_phone`, `contact_notes`, `checkout_time`,
`escalation_email`, `overdue_after_minutes`, `logo`, `welcome_image`.
**Not** editable here: `slug`, `status`, `powered_by_visible`, `ai_enabled`, `ai_daily_token_budget`
(platform-admin only — a test must assert that posting them from the staff form does not change them).
Pundit: only `hotel_admin` may update; plain `staff` gets 403.
The edit page includes a **live preview** panel: a small mock of the guest landing header rendered
with the current colors and logo, updated by a Stimulus controller
(`app/javascript/controllers/brand_preview_controller.js`) as the colour inputs change. Keep it to
CSS-variable updates on a preview element — no canvas, no dependencies.

- [ ] **Step 5: Controller tests**

- hotel_admin can update branding; plain staff gets 403
- posting `powered_by_visible=false` / `ai_enabled=false` / `slug=...` from the staff form leaves
  those attributes unchanged
- a staff user of hotel A gets 404/403 when trying to update hotel B (there is no id in the path —
  assert that the controller always uses `Current.hotel`, e.g. by signing in as hotel A's admin and
  asserting hotel B is untouched after an update)

- [ ] **Step 6: System test + commit**

`test/system/hotel_branding_test.rb` — hotel admin signs in, changes the primary color and concierge
name, uploads a logo (use `file_fixture`), saves, and sees the new values persisted.

---

### Task 4: Rooms, departments, and request categories

**Why this task exists:** the guest entry form validates room numbers against this list (Slice 2), and
the AI's service-request categories are generated per hotel from this table (Slice 4). Hotels must be
able to configure their own — no hardcoded lists.

**Files:**
- Create: `db/migrate/*_create_rooms.rb`, `db/migrate/*_create_departments.rb`, `db/migrate/*_create_request_categories.rb`
- Create: `app/models/room.rb`, `app/models/department.rb`, `app/models/request_category.rb`
- Create: `app/controllers/staff/rooms_controller.rb`, `app/controllers/staff/departments_controller.rb`, `app/controllers/staff/request_categories_controller.rb`
- Create: views for each (`index` with inline new/edit forms is fine — keep it to few screens)
- Create: `app/services/hotel_defaults.rb`
- Create: `test/models/room_test.rb`, `test/models/request_category_test.rb`, `test/services/hotel_defaults_test.rb`
- Create: `test/controllers/staff/rooms_controller_test.rb`
- Create: `test/tenancy/cross_tenant_access_test.rb`
- Create: `test/fixtures/rooms.yml`, `test/fixtures/departments.yml`, `test/fixtures/request_categories.yml`
- Modify: `config/routes.rb`, `app/models/hotel.rb`, `app/controllers/platform/hotels_controller.rb` (seed defaults on create)

**Schema:**

`rooms`: `hotel_id` null: false FK, `number` string null: false, `active` boolean null: false default true,
timestamps. Unique index `[hotel_id, number]`. Index `[hotel_id, active]`.

`departments`: `hotel_id` null: false FK, `name` string null: false, `active` boolean null: false
default true, `position` integer null: false default 0, timestamps. Unique index `[hotel_id, name]`.

`request_categories`: `hotel_id` null: false FK, `department_id` FK nullable, `key` string null: false,
`name` string null: false, `icon` string, `active` boolean null: false default true, `position`
integer null: false default 0, `detail_fields` jsonb null: false default `[]`, timestamps.
Unique index `[hotel_id, key]`.

`detail_fields` holds the ordered list of details the AI must gather for this category, e.g.
`["quantity"]` for towels, `["time"]` for a wake-up call, `["date","time","people"]` for a restaurant
reservation, `["description"]` for maintenance. Slice 4's AI tool reads it. Allowed values:
`quantity`, `time`, `date`, `people`, `description`. Validate that every element is in that set.

**Carried forward from Task 2 — read before you touch the platform hotels index.** That index shows
per-hotel staff counts using one cross-hotel grouped query, which is legal only because `User` is a
tenant-*exempt* model. `Room` **is** tenant-scoped, so the same shape —
`Room.where(hotel_id: ids).group(:hotel_id).count` — will **raise** `ActsAsTenant::Errors::NoTenantSet`
under `require_tenant = true`. To add the room count to that index, wrap a per-hotel count in
`ActsAsTenant.with_tenant(hotel) { ... }` and accept the N+1 (a pilot has a handful of hotels), or
justify an explicit escape in a comment. Do not "fix" the raise by relaxing `require_tenant` or by
reaching for `without_tenant` outside `app/controllers/platform/` — the grep test will fail you, and
correctly.

**Interfaces produced:**
- `Room`, `Department`, `RequestCategory` — all `include TenantScoped`
- `HotelDefaults.apply!(hotel)` — idempotently creates the default departments and request categories
  for a newly created hotel. Called from `Platform::HotelsController#create` inside
  `ActsAsTenant.with_tenant(hotel) { ... }`.
- `Hotel#find_active_room(number)` — normalizes the input (strip, upcase, collapse whitespace) and
  returns the matching active `Room` or nil. Slice 2's guest entry form and Slice 6's WhatsApp
  `set_guest_room` tool both call exactly this.
- `Room.parse_bulk(text)` → array of normalized room-number strings, expanding ranges.

- [ ] **Step 1: Write the failing `Room.parse_bulk` test**

```ruby
# test/models/room_test.rb  (excerpt)
test "parse_bulk expands numeric ranges and splits on commas and newlines" do
  assert_equal %w[101 102 103 201 202], Room.parse_bulk("101-103, 201\n202")
end

test "parse_bulk keeps non-numeric room labels intact" do
  assert_equal %w[PH1 A12], Room.parse_bulk("PH1, A12")
end

test "parse_bulk deduplicates and ignores blanks" do
  assert_equal %w[101 102], Room.parse_bulk("101, 101, ,102")
end

test "parse_bulk refuses an absurd range rather than generating 100k rooms" do
  assert_raises(Room::BulkRangeTooLarge) { Room.parse_bulk("1-99999") }
end
```
Cap a single range at 500 rooms. This is a real guard: a typo like `1-99999` must not create 99,999
rows on a pilot database.

- [ ] **Step 2: Write the failing `find_active_room` test**

```ruby
test "find_active_room normalizes case and whitespace" do
  hotel = hotels(:stari_grad)
  ActsAsTenant.with_tenant(hotel) do
    room = hotel.rooms.create!(number: "PH1")
    assert_equal room, hotel.find_active_room(" ph1 ")
    assert_nil hotel.find_active_room("PH2")
  end
end

test "find_active_room ignores inactive rooms" do
  hotel = hotels(:stari_grad)
  ActsAsTenant.with_tenant(hotel) do
    hotel.rooms.create!(number: "999", active: false)
    assert_nil hotel.find_active_room("999")
  end
end
```

- [ ] **Step 3: Write the cross-tenant access test (the spec-required isolation suite)**

`test/tenancy/cross_tenant_access_test.rb` — sign in as hotel A's admin and request every
tenant-scoped staff route with hotel B's record ids, asserting 404 (not 403 — a foreign record must
be invisible, not merely forbidden; 403 confirms the record exists). Cover rooms, departments, and
request categories now; extend this file in later slices as new resources appear.

```ruby
test "hotel A staff cannot read or mutate hotel B's rooms" do
  vrelo_room = ActsAsTenant.with_tenant(hotels(:vrelo)) { hotels(:vrelo).rooms.create!(number: "B-1") }
  sign_in users(:stari_admin)

  get edit_staff_room_path(vrelo_room)
  assert_response :not_found

  patch staff_room_path(vrelo_room), params: { room: { number: "HACKED" } }
  assert_response :not_found
  assert_equal "B-1", vrelo_room.reload.number
end
```

- [ ] **Step 4: Implement models, `HotelDefaults`, and controllers**

`HotelDefaults.apply!(hotel)` creates departments **Reception, Housekeeping, Maintenance, Food &
Beverage** and these categories (key → name → department → detail_fields):
- `room_items` → "Extra towels, bedding or toiletries" → Housekeeping → `["quantity","description"]`
- `cleaning` → "Room cleaning" → Housekeeping → `["time"]`
- `maintenance` → "Report a problem" → Maintenance → `["description"]`
- `wake_up_call` → "Wake-up call" → Reception → `["time"]`
- `dining_reservation` → "Restaurant or breakfast reservation request" → Food & Beverage → `["date","time","people"]`
- `spa_reservation` → "Spa or wellness reservation request" → Reception → `["date","time","people"]`
- `transport` → "Taxi, airport transfer or luggage help" → Reception → `["time","description"]`
- `reception` → "Something else for reception" → Reception → `["description"]`
Idempotent: `find_or_create_by!(key:)`. The names above are the English defaults; the hotel edits
them freely (including into Bosnian) and the AI uses whatever the hotel stored.

Rooms controller: `index` (list + inline add-single form + a "bulk add" textarea), `create`,
`update` (toggle active / rename), `destroy` (only if the room has no dependent records — in this
slice nothing depends on it yet, so a plain destroy is fine; guard it with `dependent: :restrict_with_error`
on future associations rather than deleting silently later).
Bulk add reports how many rooms were created and how many were skipped as duplicates.

Departments and categories controllers: simple CRUD, reorder by `position` (a plain integer field
edited in the form is fine — no drag-and-drop). Deactivating rather than deleting is the default
action offered in the UI; deletion is allowed only when nothing references the record.

Wire `HotelDefaults.apply!(hotel)` into `Platform::HotelsController#create`.

- [ ] **Step 5: Fixtures, full suite, commit**

Add rooms/departments/request_categories fixtures for **both** hotels (isolation tests need data on
each side of the boundary).

---

### Task 5: Staff accounts

**Files:**
- Create: `app/controllers/staff/users_controller.rb`, views (`index`, `new`, `edit`)
- Create: `app/policies/user_policy.rb`
- Create: `test/controllers/staff/users_controller_test.rb`
- Modify: `config/routes.rb`, `test/tenancy/cross_tenant_access_test.rb` (add user routes)

**Interfaces consumed:** `Staff::BaseController`, `User`, Pundit.

- [ ] **Step 1: Write the failing tests**

- a hotel_admin can create a staff user, and the new user belongs to `Current.hotel` **even if the
  form posts a different `hotel_id`** (assert this explicitly — mass-assignment of `hotel_id` must be
  impossible)
- a hotel_admin can deactivate a user; a deactivated user cannot sign in
- a plain `staff` user gets 403 on every users route
- a hotel_admin cannot create a `platform_admin` (assert the role param is rejected/ignored and the
  created user is `staff` or `hotel_admin` only)
- hotel A's admin gets 404 editing hotel B's user
- a hotel_admin cannot deactivate their own account (lock-out guard)

- [ ] **Step 2: Implement**

Roles offered in the form: `staff` and `hotel_admin` only. Password is set by the admin at creation
(assisted onboarding — no invitation email in this slice; the flash tells the admin to hand the
credentials over securely). `AuditLog.record!` on create and on deactivate, with
`hotel: Current.hotel`.

- [ ] **Step 3: Full suite, commit**

---

### Task 6: The hotel's reusable QR code and printable sheet

**Why this task exists:** acceptance scenario 2 ends with "downloads the hotel's reusable QR code".
Exactly **one** QR per hotel, printed for every room and common area — not one per room.

**Files:**
- Create: `app/services/hotel_qr_code.rb`
- Create: `app/controllers/staff/qr_codes_controller.rb`
- Create: `app/views/staff/qr_codes/show.html.erb`, `app/views/staff/qr_codes/print.html.erb`
- Create: `test/services/hotel_qr_code_test.rb`, `test/controllers/staff/qr_codes_controller_test.rb`
- Create: `test/system/qr_download_test.rb`
- Modify: `config/routes.rb`, `config/environments/*.rb` (default_url_options / APP_HOST)

**Interfaces produced:**
- `HotelQrCode.new(hotel, host:).url` → `"https://<host>/h/<slug>"` — Slice 2's guest landing route
  must match this exactly.
- `HotelQrCode#svg(size:)` → SVG string; `#png(size:)` → PNG binary string.

- [ ] **Step 1: Write the failing service test**

```ruby
# test/services/hotel_qr_code_test.rb
require "test_helper"

class HotelQrCodeTest < ActiveSupport::TestCase
  test "encodes the hotel's public landing URL" do
    qr = HotelQrCode.new(hotels(:stari_grad), host: "hospello.example")
    assert_equal "https://hospello.example/h/stari-grad", qr.url
  end

  test "the same hotel always produces the same URL — one reusable code per hotel" do
    a = HotelQrCode.new(hotels(:stari_grad), host: "hospello.example").url
    b = HotelQrCode.new(hotels(:stari_grad), host: "hospello.example").url
    assert_equal a, b
  end

  test "different hotels produce different URLs" do
    refute_equal HotelQrCode.new(hotels(:stari_grad), host: "h.example").url,
                 HotelQrCode.new(hotels(:vrelo), host: "h.example").url
  end

  test "renders an SVG containing the QR modules" do
    svg = HotelQrCode.new(hotels(:stari_grad), host: "h.example").svg(size: 300)
    assert_includes svg, "<svg"
  end
end
```

- [ ] **Step 2: Implement the service and controller**

`Staff::QrCodesController#show` — an on-screen page with the QR, the URL as text, a "Test it yourself"
link, and download buttons. `#show` responds to `format.svg` and `format.png` with
`send_data` and a filename like `hospello-qr-stari-grad.svg`.
`#print` renders a printable A5 sheet: hotel logo, a large QR, a short headline and instruction line
in **all four guest languages (bs, en, de, ar)**, the reception phone number, and a discreet
"Powered by Hospello" line **only when `hotel.powered_by_visible`**. Include a print stylesheet
(`@media print`) that hides the app chrome. The Arabic line must render right-to-left — set
`dir="rtl"` on that element.

The host comes from `ENV["APP_HOST"]` in production and `request.host_with_port` in development, so a
pilot hotel's printed code always points at the real deployment. Do not hardcode a domain.

- [ ] **Step 3: Controller/system tests**

- the SVG download responds 200 with `image/svg+xml` and a filename containing the slug
- the print view contains the four language lines and the hotel's phone number
- with `powered_by_visible = false` the print view does **not** contain "Powered by Hospello"
- a plain staff user may view the QR page (receptionists reprint cards — this is not admin-only)

- [ ] **Step 4: Full suite, commit**

---

### Task 7: Ops, Render deployment, and CI

**Why this task exists:** acceptance scenario 13 ("the complete application can be deployed and
operated on Render using documented steps") and the plan's unattended-pilot mandate.

**Files:**
- Create: `render.yaml`, `bin/render-build.sh` (executable)
- Create: `config/initializers/sentry.rb`, `config/initializers/lograge.rb`, `config/initializers/rack_attack.rb`
- Create: `app/jobs/ops/heartbeat_job.rb`, `app/jobs/ops/queue_health_job.rb`
- Create: `test/jobs/ops/heartbeat_job_test.rb`
- Create: `.github/workflows/ci.yml`
- Create: `.env.example`
- Create: `README.md` (replace the generated one)
- Create: `docs/runbook.md`, `docs/whatsapp-onboarding.md`
- Modify: `config/recurring.yml`, `config/queue.yml`, `config/routes.rb` (mount Mission Control), `config/environments/production.rb`

- [ ] **Step 1: Queues and recurring jobs**

`config/queue.yml` — four queues with the concurrency the plan specifies:
```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: critical
      threads: 3
      processes: 1
      polling_interval: 0.5
    - queues: ai
      threads: 2
      processes: 1
      polling_interval: 1
    - queues: [ default, low ]
      threads: 2
      processes: 1
      polling_interval: 2
development:
  <<: *default
test:
  <<: *default
production:
  <<: *default
```
The `ai` thread cap is deliberate backpressure: if the Anthropic API slows to 30s per call, at most
two calls are in flight and nothing else in the system degrades. Document that in a comment.

`config/recurring.yml` — `ops_heartbeat` every 5 minutes, `ops_queue_health` every 10 minutes.
(Later slices add the conversation, escalation, and retention jobs; leave a comment saying so.)

- [ ] **Step 2: Heartbeat and queue-health jobs**

`Ops::HeartbeatJob` includes `TenantFree`, queue `low`. It GETs `ENV["HEARTBEAT_URL"]` when present
and no-ops (without raising) when it is blank — a missing heartbeat URL must never break a
deployment. It runs **from the queue**, so a live web process with a dead queue stops pinging and
the external monitor pages. Explain that in a comment; it is the point of the job.

`Ops::QueueHealthJob` includes `TenantFree`, queue `low`. It reads
`SolidQueue::FailedExecution.count` and the age of the oldest ready job, and reports to Sentry
(`Sentry.capture_message`) when failures > 0 or the oldest ready job is older than 5 minutes.

Test with WebMock: heartbeat pings the configured URL; a blank URL performs no HTTP call and does
not raise; a failing ping does not raise (it logs).

- [ ] **Step 3: Rack::Attack**

`config/initializers/rack_attack.rb` — throttles keyed for the public guest surface that Slice 2 adds:
- `throttle("guest_entry/ip", limit: 20, period: 1.minute)` on POSTs to `/h/...` paths
- `throttle("guest_messages/ip", limit: 60, period: 1.minute)` on `/guest/...` POSTs
- `throttle("logins/ip", limit: 10, period: 1.minute)` on POSTs to the session path
- a `safelist` for requests to `/up`
- **A comment reserving the webhook exemption**: Slice 6 adds `/webhooks/whatsapp`, and
  signature-valid webhook requests must be safelisted there — a throttled webhook endpoint gets the
  provider to back off and silently drop guest messages.
Disabled in the test environment except in tests that explicitly enable it
(`Rack::Attack.enabled = false` in `config/environments/test.rb`).

- [ ] **Step 4: Sentry, lograge, Mission Control**

Sentry: initialize only when `SENTRY_DSN` is present; `traces_sample_rate` 0.1; scrub params.
Lograge: JSON output in production; `custom_options` adds `hotel_id` (from `Current.hotel&.id`),
`user_id`, and `request_id`.
Mission Control: mount at `/platform/jobs`, protected so only a signed-in `platform_admin` reaches it
(use its `MissionControl::Jobs.base_controller_class` pointing at `Platform::BaseController`, and
disable its default HTTP basic auth — our session auth is the gate).

- [ ] **Step 5: `render.yaml`, build script, and `.env.example`**

`bin/render-build.sh` (chmod +x):
```bash
#!/usr/bin/env bash
set -o errexit
bundle install
bundle exec rails assets:precompile
bundle exec rails assets:clean
```

`render.yaml` exactly as specified in the approved plan's "Render deployment" section: one `web`
service (`runtime: ruby`, `plan: starter`, `buildCommand: ./bin/render-build.sh`,
`preDeployCommand: bundle exec rails db:migrate`, `startCommand: bundle exec puma -C config/puma.rb`,
`healthCheckPath: /up`), all listed env vars (secrets `sync: false`), plus the `databases:` block with
`hospello-db` on `plan: basic-256mb`. Include the commented-out `worker` service block with a comment
naming the split trigger (sustained queue-health latency alerts, expected around hotel #5).

`config/puma.rb` — ensure the Solid Queue plugin line the Rails 8 generator ships
(`plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]`) is present.

`.env.example` — every env var the app reads, with a short comment each and **no real values**.

- [ ] **Step 6: CI**

`.github/workflows/ci.yml` — a Postgres service container, Ruby from `.ruby-version`, then:
`bin/rails db:prepare`, `bin/rails test`, `bin/rails test:system`, `bundle exec rubocop`,
`bundle exec brakeman --no-pager`, `bundle exec bundler-audit check --update`.

- [ ] **Step 7: Documentation**

`README.md` — what Hospello is, local setup (Postgres, `bin/setup`, `bin/dev`), how to run tests, the
env-var table, and a "Deploy to Render" section with the exact click-path and the first-boot steps
(create the platform admin via `PLATFORM_ADMIN_EMAIL`/`PLATFORM_ADMIN_PASSWORD` seeds, sign in, create
the first hotel).

`docs/runbook.md` — the incident runbook skeleton: how to check queue health, where the heartbeat
lives, how to read Sentry, how to suspend a hotel, how to rotate a leaked QR (a hotel's slug), and a
placeholder section per later-slice failure mode (AI outage, translation failure, WhatsApp delivery)
that later slices fill in.

`docs/whatsapp-onboarding.md` — the hotel-facing WhatsApp checklist, clearly separating **what
Hospello does**, **what the hotel must provide** (legal/trading name, display name, a number —
Coexistence on their existing WhatsApp Business number is the low-friction default — a Meta Business
portfolio, and an opt-in checkbox in their booking flow), and **what is outside anyone's control**
(Meta display-name review, typically 1–7 business days; business verification, 1 day–2 weeks, needed
only above 250 business-initiated conversations/day). State plainly that the product is fully usable
before WhatsApp is connected.

- [ ] **Step 8: Seeds**

`db/seeds.rb` — idempotent. Creates the platform admin from `PLATFORM_ADMIN_EMAIL` /
`PLATFORM_ADMIN_PASSWORD` via `find_or_create_by!` (skipping with a clear log line when the env vars
are absent). Loads `db/seeds/demo.rb` only when `ENV["SEED_DEMO"] == "1"` — create that file with a
single comment for now (`# Populated in Slice 7`), so the hook exists and the path is proven.

- [ ] **Step 9: Full suite, `bin/rails zeitwerk:check`, brakeman, commit**
