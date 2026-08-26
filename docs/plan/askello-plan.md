# Askello — a second product on the Hospello platform: implementation plan

> **Status: SUPERSEDED as the build path — the owner chose the fork instead.** See
> [askello-fork-plan.md](askello-fork-plan.md): Askello is being built in a separate repository
> cloned from this one, not as a second brand inside this app. **This document remains the audit of
> record** (§1–3: what exists, what's reusable, the gaps) **and the reference design for the
> net-new subsystems** (§4–5: auth/signup, guide builder, AI generation, public guide, billing,
> analytics — the fork plan's phases F2–F6 point back here for their detail). The monolith-specific
> machinery in it — the `product` enum, `Brand` registry, host constraints, product gates, pin
> tests — is void under the fork and must not be built.
>
> Original status when written (2026-08-26, against `81caf79`): plan only, nothing implemented —
> no migration run, no model or route created.
>
> **Before implementing:** this plan is a *proposal*, not an approved contract like
> [implementation-plan.md](implementation-plan.md). Section 10 lists nine open questions, each with
> a recommended default — several (the Free plan's AI allowance, one Askello host vs. a marketing/app
> split, whether Hospello staff also get password reset) are product decisions the owner should
> confirm before the phase that depends on them. Phases 0–1 depend on none of them and are safe to
> start.
>
> **Where the audit came from:** three parallel repository audit passes plus an adversarial design
> review, all line-verified against the working tree. Where this document cites a file and line, it
> was read, not assumed. The one thing it could *not* verify is anything requiring an
> `ANTHROPIC_API_KEY` or a live Render/Stripe account — see §10.

## Context

Hospello is a live, multi-tenant hotel guest-communication platform (QR → branded guest chat → AI concierge grounded in a per-hotel knowledge base → reception dashboard), sold assisted, hotel-by-hotel. The owner now wants a second commercial product, **Askello** — "Every answer for every stay.", an *AI guest guide for vacation rentals* — sold entirely self-service to Airbnb/vacation-rental hosts with 1–10 properties: sign up online, paste a listing description, let AI structure it into an editable guest guide, publish a mobile public guide with grounded AI Q&A, share a link/QR, pay by Stripe subscription.

The mandate: one repo, one Rails app, one Render service, one Postgres database; separate brands, domains, onboarding, dashboards, plans, and public experiences; shared platform underneath; Hospello must not break and its data must not be touched. This plan is the result of a full repository inspection (three parallel audit passes plus an adversarial design review) and is written so implementation can begin without repeating the analysis.

**Verdict up front:** the shared-platform approach is not merely acceptable — this codebase is unusually well-prepared for it. Tenancy fails closed and is tripwire-tested; a plan/feature-gating seam (`Hotel#plan_allows?` + `PlanGated`) already exists; the AI concierge already has a Q&A-only mode ("Essentials" plan) that is exactly Askello's AI shape, tested end-to-end including live against the real model; the guest surface is already product-neutral (hotel-branded, `powered_by_visible` toggle); and the WhatsApp path already proves roomless, formless guest sessions work. The genuinely new work is: self-service auth (signup/password reset/mailers — none exist), a marketing site (none exists), a host dashboard namespace, a public guide renderer, Stripe billing (none exists), an events/UTM layer (none exists), and multi-host brand resolution (nothing routes on host today).

---

## 1. Current architecture audit

*(Everything below verified against the working tree at `81caf79` on branch `claude/askello-product-planning-si0r34`; working tree clean, no uncommitted changes to preserve. Rails 8.1.3.1 (`load_defaults 8.0`), Ruby 3.4.3. 1,301 unit/integration tests + 41 system tests green per HANDOVER.md; slices 1–6 complete, slice 7 lacking only Task 5 (hardening/walkthrough).)*

### Application architecture
- Single Rails monolith, Hotwire (Turbo 8 + Stimulus via importmap, no Node), Propshaft, Tailwind v4 standalone. One Postgres serves app data **and** Solid Queue/Cache/Cable (`config/database.yml` deliberately single-connection; Solid tables live in the main schema via `db/migrate/20260806171504_create_solid_tables.rb`).
- Solid Queue runs **inside Puma** (`SOLID_QUEUE_IN_PUMA`, `config/puma.rb:62-66`), three worker pools: `critical` (3 threads), `ai` (2 — deliberate backpressure), `default,low` (2). Recurring jobs in `config/recurring.yml` (production-only block): heartbeat, queue health, draft expiry, translation watchdog, nightly retention purge 03:20.
- Namespaces: `/h/:hotel_slug` (guest entry, the printed QR target), `/guest/*` (cookie-scoped guest chat), `/staff/*` (hotel dashboard), `/platform/*` (platform admin + Mission Control at `/platform/jobs`), `/webhooks/whatsapp`, `/up`. **Root `/` is the bare sign-in form** (`config/routes.rb:214` → `sessions#new`) — there are no marketing pages of any kind.

### Data model
- **`Hotel` is the tenant root** (`app/models/hotel.rb`). There is **no Account/Organization above it**, no `product_type`/`brand`/`vertical` column anywhere; `hotels.settings` jsonb (default `{}`) exists and is read/written by **nothing** — a free extension slot. Slug globally unique, `/\A[a-z0-9][a-z0-9-]*\z/`, derived from `name.parameterize`.
- 18 tenant tables carry `hotel_id` (NOT NULL, FK, cascade) — rooms, departments, request_categories, guest_sessions, conversations, messages, kb_entries, service_requests(+drafts), request_events, unanswered_questions, ai_runs, ai_usage_days, whatsapp_channels(+templates). Three carry `hotel_id` but are exempt from tenancy with written justification: `users` (nullable for platform admins), `audit_logs`, `webhook_events` (written pre-routing).
- `KbEntry`: `category` enum `{facilities:0, dining:1, rooms:2, policies:3, local_area:4, transport:5, other:6}` (hotel-shaped vocabulary that **travels into the AI prompt** as an attribute), `title` unique per hotel, `content` ≤2000 chars, `published` bool (default false), `ordered` = `(position, id)` — the id tiebreak is load-bearing for prompt-cache determinism. `Hotel#published_kb_entries` is the single answer to "what may the model see".
- `GuestSession`: web sessions require name + room (validated against `hotel.rooms.active`) + consent; **WhatsApp sessions are the precedent Askello needs** — roomless, formless, consent stamped from the guest's own first message (`GuestSession.for_whatsapp`), identity forced `unverified` by a `before_save`.
- `Conversation`/`Message`: one live conversation per guest (partial unique index), `client_message_id` dedupe, `guest_visible`/`internal` visibility with four tested guest-facing reads, DB-first + `after_commit` broadcasts + resync/polling resilience.

### Authentication and authorization
- Rails 8 auth generator, no Devise. **No self-service signup, no password reset, no email confirmation, and no mailers at all** — `app/mailers/` contains only the `ApplicationMailer` stub, no SMTP is configured, nothing in the app ever sends email (`config/environments/production.rb:93-99` commented out). Users are created only by platform admins (`Platform::HotelAdminsController`) or hotel admins (`Staff::UsersController`, roles whitelisted to `staff`/`hotel_admin`).
- Roles: `{staff:0, hotel_admin:1, platform_admin:2}`; `users.hotel_id` nullable **only** for platform_admin, enforced by `User#hotel_membership_matches_role` (`app/models/user.rb:59-65`).
- Pundit for **role** questions (16 policies; `HotelConfigurationPolicy` gives the read-for-staff/write-for-admin split). Plan questions deliberately live elsewhere (see below). Staff controllers never take a hotel id from the URL — everything goes through `Current.hotel.<assoc>`, so foreign ids 404 before Pundit runs.

### Tenant isolation
- `acts_as_tenant :hotel` with `require_tenant = true` (`config/initializers/acts_as_tenant.rb`) — unscoped queries **raise**. Guest requests resolve tenant from the signed cookie; staff from `Current.user.hotel`; platform sets no ambient tenant and is the only namespace where escape hatches are allowed.
- Four tripwire suites police this and **will fire on new Askello code**: `test/tenancy/tenant_declaration_test.rb` (auto-scans every model with a `hotel_id` column for `acts_as_tenant`, with a justified `EXEMPT` list), `without_tenant_grep_test.rb` (greps `app/ lib/ db/ config/` for seven escape-hatch patterns; allowed only under `app/controllers/platform/` plus two named `find_by_sql` pre-tenant lookups), `controller_tenant_scoping_test.rb`, `cross_tenant_access_test.rb` (the "404, not 403" suite, ~30 scenarios incl. Cable and webhooks). Additionally `test/services/retention/policy_test.rb` fails on any new `hotel_id` table without a retention decision in `app/services/retention/policy.rb`.

### AI implementation
- `Ai::Client` (`app/services/ai/client.rb`) is the only file naming `Anthropic::`; `#chat(system:, messages:, tools:, model:, max_tokens:, effort:, timeout:)` → `Ai::Result`. `FakeClaude` (`test/support/fake_claude.rb`) returns real `Ai::Result` objects and records calls, so prompts themselves are testable. Models configured once in `config/initializers/ai.rb` (`AI_MODEL` default `claude-opus-5`, `TRANSLATION_MODEL` default `claude-haiku-4-5`, `ANTHROPIC_API_KEY`).
- `Ai::PromptBuilder` (`app/services/ai/prompt_builder.rb`): three system blocks — (1) static rules, **already branching by plan**: `SERVICE_RULES` vs `ESSENTIALS_RULES` chosen by `plan_allows?(:requests)` (`:163-164`); (2) hotel card + **entire published KB inlined** as `<kb_entry id category title>` with the one `cache: true` breakpoint (no retrieval by design — a rental's KB is even smaller than a hotel's, so this transfers perfectly); (3) volatile context (`<current_context>`, `<room_unknown>` when the session is roomless, `<pending_draft>`). Guest text sealed in `<guest_message>` with `<` neutralized. Citations `[kb: N]` are validated against real published entries and audited on `AiRun.cited_kb_entry_ids`.
- `Ai::Tools`: `escalate_to_staff`, `log_unanswered_question`, `set_guest_room` always; `propose_service_request`/`confirm_service_request` only when `plan_allows?(:requests)` — **double-gated** (tool list `tools.rb:194` *and* dispatch refusal `tools.rb:215`). The Essentials (Q&A-only) concierge is complete and verified live (`test/services/ai/essentials_plan_test.rb`, `live_essentials_test.rb`).
- `Ai::GenerateReplyJob`: `:ai` queue, per-conversation serialization, message coalescing, four guards (paused / `ai_enabled` / circuit breaker / budget ≥90%). `Ai::CircuitBreaker` per hotel in Rails.cache. **Budget**: `hotels.ai_daily_token_budget` (default 500,000) → `AiRun` → `AiUsageDay` rollup in the hotel's timezone; **budget 0 = "exhausted", not "unlimited" — proven semantics** the Askello Free plan can reuse directly. Injection corpus: 21 jailbreak shapes asserting structural guarantees (`test/services/ai/injection_corpus_test.rb`). Translation pipeline (`Ai::Translator` + `Ai::DigitGuard` multiset digit equality) exists and never raises.

### Public guest experience
- `/h/:slug` renders the hotel-branded landing (logo, colors as CSS custom properties via `BrandingHelper#hotel_brand_style` with real WCAG contrast selection, `theme-color` meta) → entry form → chat. `app/views/layouts/guest.html.erb` is explicitly product-neutral ("The hotel — not Hospello — is the brand"); "Powered by Hospello" is per-hotel toggleable (`powered_by_visible`). Guest chrome locales bs/en/de/ar with correct RTL; the AI replies in the guest's language natively (prompt rule, no detection call).
- Known issue (documented, decision pending): `allow_browser versions: :modern` on `ApplicationController` 406s Safari <17.2 / Chrome <120 with an unbranded English page — this gate will sit in front of Askello marketing pages too unless addressed.

### Billing
- **None. Confirmed exhaustively** — no Stripe/payment/trial/invoice code, gem, or config anywhere. What exists is a *capability profile*: `Hotel.plan` enum `{essentials:0, service:1, revenue:2}` (default `service` = "the app as built"), `PLAN_FEATURES` (`essentials: []`, `service: [:requests]`, `revenue: [:requests, :upsell]`), the single predicate `Hotel#plan_allows?(feature)` (13 call sites), `PlanGated#requires_plan_feature` rendering a translated 403 upgrade page, and `room_limit`/`PLAN_ROOM_LIMITS` with `effective_room_limit`. Plans are changed only by platform admins (`Platform::HotelsController#plan`, audit-logged).

### QR functionality
- `HotelQrCode.new(hotel, host:)` — `#path` = `"/h/#{slug}"` (the one place that shape is written, pinned by routing tests), `#url` = `"https://#{host}#{path}"`, exact-size SVG + PNG (`rqrcode`). `Staff::QrCodesController` (SVG/PNG download + printable A5 sheet); `QrCardHelper` prints multi-language card copy that already branches on plan (`plan_allows?(:requests)` → "chat with our front desk" vs "ask anything"). The service already takes `host:` as a parameter — per-product hosts slot in cleanly.

### Branding / domain handling
- **Nothing routes on host.** `APP_HOST` is a single scalar resolved once at boot (`AppHost.resolve!` → `config.x.app_host` + `action_mailer.default_url_options`, `config/environments/production.rb:86-90`); `config.hosts` allowlist is entirely commented out; only the QR controller and one view read `request.host` at all. "Hospello" appears as a literal in 33 files (staff/platform layouts, locale keys, cookie name `hospello_guest`, QR filenames, `module Hospello`); the guest surface and the `public/` error pages are already brand-free.

### Render deployment
- `render.yaml`: one web service (plan `free`, Frankfurt, branch `main`, `healthCheckPath: /up`) + one free Postgres. **Migrations run inside `bin/render-build.sh`** (free tier has no `preDeployCommand`), followed by an idempotent `db:seed`; new code is briefly live against the old schema on every deploy — all Askello migrations must therefore be strictly additive/backward-compatible. Env vars: `APP_HOST`, `RAILS_MASTER_KEY`, `ANTHROPIC_API_KEY`, `PLATFORM_ADMIN_*`, `WHATSAPP_*`, `R2_*` (Active Storage → Cloudflare R2 when `R2_BUCKET` present, else local disk), `SENTRY_DSN`, `HEARTBEAT_URL`, `SOLID_QUEUE_IN_PUMA`, `WEB_CONCURRENCY=1`, `RAILS_MAX_THREADS=5`.
- Ops: Sentry (no-op without DSN), lograge JSON with `hotel_id`/`user_id`, queue-originated dead-man heartbeat, `Ops::QueueHealthJob`, Rack::Attack (path-prefix throttles on `POST /h/`, `POST /guest/`, `POST /session`; signature-verified WhatsApp safelist), strict CSP (`script_src :self` + per-request nonce; `style_src 'unsafe-inline'` deliberately, for inline brand colors).

### Analytics and events
- Server-side only: `Analytics::HotelReport` (one object read by both the staff page and the platform rollup). **Zero client-side tracking, zero UTM handling, no events table, no third-party tags** — and the CSP as written would block third-party scripts. Greenfield for Askello's funnel events.

### Test coverage
- 125 test files / ~1,341 cases: models, controllers (per namespace), jobs, services (13 AI files), channels, i18n structural tests (locale files read **off disk**, per-family key-set equality — new locale families must register in `FAMILY_LOCALES`), tenancy (4 suites above), seeds (loads the real seed), 15 system tests (headless Chrome; the harness's leak-detection settings and per-test driver quit are load-bearing — do not touch). House rule with 20+ paid-for instances behind it: **prove every guarding test can fail** (break the code, watch red, restore). WebMock blocks all network; `FakeClaude` above the seam; three `LIVE_AI=1` live tests (never yet run — no session has had an API key).

---

## 2. Reusable Hospello components

| Existing component | Relevant files | Reusable as-is? | Changes needed for Askello | Risk |
|---|---|---|---|---|
| Tenancy (fail-closed) + tripwire suites | `app/models/concerns/tenant_scoped.rb`, `config/initializers/acts_as_tenant.rb`, `test/tenancy/*` | **Yes** | None to the mechanism. New models/namespaces must register with the tripwires (TenantScoped or justified EXEMPT; grep allowlist only if genuinely needed) | Low |
| `Hotel` as tenant/property root | `app/models/hotel.rb` | Yes, extended | Add `product` enum, `account_id` FK, `guide_published_at`; Askello properties are Hotels with `plan: essentials`, zero rooms. **No rename** | Low–Med |
| Plan gating seam | `hotel.rb:29-101` (`plan_allows?`), `app/controllers/concerns/plan_gated.rb` | **Yes** | Untouched for Hospello. Askello's *commercial* plan lives on the new `Account`; `hotels.plan` stays the operational capability profile (`essentials` for every Askello property) | Low |
| AI seam + concierge | `app/services/ai/client.rb`, `concierge.rb`, `generate_reply_job.rb`, `outcome.rb`, `result.rb`, `test/support/fake_claude.rb` | **Yes** | None to the seam. One new caller (guide generation) | Low |
| Prompt grounding | `app/services/ai/prompt_builder.rb` | Mostly | Third rules variant (GUIDE_RULES: no room-asking, "contact host" wording); hotel-card lines for host contact; product-aware section | Med |
| AI tools | `app/services/ai/tools.rb` | Mostly | Withhold `set_guest_room` for Askello properties (both gates, same double-gate pattern as request tools) | Low–Med |
| Budget / circuit breaker / telemetry | `ai_run.rb`, `ai_usage_day.rb`, `circuit_breaker.rb` | **Yes** | New `AiRun` kind `generation`; plan-driven `ai_daily_token_budget` values (0 = no AI is proven semantics for Free) | Low |
| Knowledge base | `app/models/kb_entry.rb`, `Hotel#published_kb_entries` | **Yes** | Append vacation-rental category enum values (append-only integers); guide renders published entries grouped by category — grounding path unchanged | Low–Med |
| Unanswered-question loop | `unanswered_question.rb`, `Ai::Tools#log_gap`, staff screen | **Yes** | Host-dashboard view reuses the model/scopes; "answer & add" links into the guide builder instead of `/staff` | Low |
| Guest sessions (roomless precedent) | `guest_session.rb` (`for_whatsapp`, roomless + consent-on-first-message) | Pattern reuse | New `guide` entry path: auto-created anonymous session for guide visitors (no form) | Med |
| Conversation/Message pipeline | `conversation.rb`, `message.rb`, resilience JS, `ConversationChannel` | **Yes** | Reused unchanged for guide Q&A chat (serialization, coalescing, dedupe, resync all inherited) | Med |
| Guest chat UI | `app/views/guest/chats/*`, chat Stimulus controllers | Partially | Q&A widget embedded in the guide page; different chrome/copy (new locale family), same mechanics | Med |
| Branding via CSS custom properties | `app/helpers/branding_helper.rb`, `layouts/guest.html.erb` | **Yes** | Property colors reuse `primary_color`/`secondary_color` + WCAG logic verbatim; guide layout consumes the same vars | Low |
| QR generation + print | `app/services/hotel_qr_code.rb`, `staff/qr_codes_*`, `qr_card_helper.rb` | Mostly | Parameterize path (`/g/:slug`) + host per product; Askello-branded print material; host-dashboard QR screen | Low |
| Rate limiting / abuse | `config/initializers/rack_attack.rb` | **Yes** | New throttles for signup, guide Q&A, Stripe webhook safelist (signature-verified, mirroring WhatsApp's) | Low |
| Webhook idempotency store | `webhook_events` table, `Webhooks::WhatsappController` pattern | **Yes** | `provider: "stripe"` rows; new controller copies the raw-body-HMAC + insert-on-conflict + job pattern | Low |
| Background jobs / queues | `config/queue.yml`, `application_job.rb` (tenant-from-args), `recurring.yml` | **Yes** | New jobs declare queue + tenant source like existing ones | Low |
| Active Storage (R2) | `config/storage.yml`, hotel logo/welcome_image validations | **Yes** | `has_many_attached :photos` on Hotel + same validation pattern; variant support needs a libvips check on Render | Low–Med |
| Retention & erasure | `app/services/retention/policy.rb`, purge job, `GuestErasure` | **Yes** | Add decisions for new tables (policy test forces this); guide Q&A conversations inherit the 90-day window | Low |
| i18n structure + structural tests | `config/locales/*`, `test/i18n/locale_files_test.rb` | **Yes** | New families (`askello`, `guide`) registered in `FAMILY_LOCALES`; en-first | Low |
| Auth (sessions) | `sessions_controller.rb`, `authentication.rb` | Partially | Shared sign-in mechanics; brand-aware layout + post-login routing for `host` role; **signup/password-reset/mailers are net-new** | Med |
| Analytics reporting | `app/services/analytics/hotel_report.rb` | Partially | Host analytics view reuses the report object (subset); funnel events are net-new | Low |
| Seeds / demo builder | `db/seeds/demo.rb`, `DemoHotelBuilder` | Pattern reuse | An Askello demo property seeded the same guarded, idempotent way | Low |
| Deployment (render.yaml, CI) | `render.yaml`, `bin/render-build.sh`, `.github/workflows/ci.yml` | **Yes** | Add env vars + custom domains; no new services | Low |
| Reception inbox / service requests / WhatsApp | `staff/conversations*`, `service_request*`, `whatsapp/*` | Not used by Askello | Nothing — stays Hospello-only behind `plan_allows?(:requests)` and the staff namespace | — |

## 3. Gaps and risks

### Genuine MVP blockers (must be built/decided before launch)
1. **No self-service auth path.** No signup, no password reset, no mailers, no SMTP. A self-service product cannot ship without password reset; this is the largest single net-new subsystem (registrations + passwords + first mailer + SMTP provider config + brand-aware URLs).
2. **No billing.** Stripe integration is net-new end to end (checkout, portal, webhooks, entitlement enforcement, plan catalog). The webhook idempotency substrate (`webhook_events`) exists and transfers.
3. **Single-host assumption.** `AppHost` is one scalar feeding QR URLs and mailer `default_url_options`; nothing routes on host. Two brands need a brand/host registry, host-constrained marketing routes, per-brand mailer hosts, and per-product QR hosts. Without this, Askello QR codes and emails would carry Hospello's domain.
4. **Public exposure of sensitive guide content.** Wi-Fi passwords/door codes on a public URL with a *guessable* slug (`name.parameterize`) is unacceptable exposure. Askello slugs must be unguessable (random suffix), guides `noindex`, plus rate limiting; a per-property access PIN is the post-MVP hardening step. (Hospello's `/h/` URLs are public *by design* — printed in rooms — and expose no KB content directly; Askello guides render content, which changes the calculus.)
5. **Room-coupling in the guest entry path.** The Hospello entry form requires a room number; Askello properties have no rooms. The guide needs its own entry (anonymous session, WhatsApp-style consent) and the AI must not ask for a room (`<room_unknown>` block + `set_guest_room` tool must be product-gated).
6. **`allow_browser :modern` 406.** Marketing pages that 406 old phones with an unbranded English error is a conversion killer and already a documented open decision. Askello marketing/guide controllers should not inherit the gate blindly (guide Q&A needs importmap ≥ Safari 16.4; static guide content needs almost nothing).
7. **Analytics/UTM layer absent.** The required funnel events and attribution have no substrate; net-new (small).

### Real but not blocking (schedule consciously)
8. **Deliverability/host hygiene:** `config.hosts` is unset (no Host-header allowlist); enabling it becomes *more* important with host-based brand resolution — do it in the same phase as brand routing, with all hosts listed.
9. **Free-tier Render capacity:** one 512MB instance runs web + all queues; adding public marketing traffic + AI generation load argues for the already-documented bump to `starter`/`standard` at Askello launch, not a new service.
10. **Fixtures/tests churn:** new NOT-NULL-with-default columns on `hotels` are safe for the 1,301 tests; new tables need fixtures; every tripwire suite (tenancy declaration, grep, retention policy, locale families) will fail until new artifacts register — this is the codebase working as designed, and each registration is a deliberate decision point.
11. **Prompt-cache hygiene:** a third rules variant multiplies static-block variants; keep the product branch inside the existing "static rules chosen per hotel" pattern (block 1 is per-hotel-plan already, so no new cache risk beyond one more variant).
12. **Vocabulary bleed:** `Hotel`/`Room`/`hotel_admin` class and role names are internal and stay; guest- and host-visible strings must come from new locale families, never from `staff.*`. `KbEntry.category` values print into the prompt and the guide nav — Askello adds its own values rather than reusing `rooms`/`dining` where they read wrong.
13. **Technical debt that does *not* need fixing first:** Rails 8.0→8.1 load_defaults drift, `.env.example` stale `SEED_DEMO` comment, missing PWA manifest, ActiveRecord attribute-name i18n, the system-test browser-launch flake, Slice 7 Task 5 hardening steps (chaos drill, PITR, LIVE_AI). None block Askello; do not entangle them.

### Tight hotel coupling — audited, with the chosen response
- `Hotel → Room` with room-number identity: **bypassed** (Askello guests are anonymous; properties have zero rooms) rather than remodeled. No "hotel with one room" hack, no rename.
- `HotelDefaults.apply!` seeds hotel departments/categories: **not called** for Askello properties (Essentials hotels already skip categories in the demo builder — same rule).
- Reception vocabulary in prompts ("call reception"): replaced by GUIDE_RULES for Askello properties. Reception vocabulary in **degraded-mode copy** (`degraded.reception_will_reply`, posted by `Ai::GenerateReplyJob#degrade!` with no model in the loop): needs a per-product sibling key in **all four** `degraded.*.yml` files at once (the structural locale test enforces family key-set equality).
- The rest of the hotel machinery (inbox, requests, WhatsApp, translations overlay UI) simply stays un-exercised for `product: askello` rows, already gated by plan/namespace.

### Security risk review (each with its planned control)
| Risk | Control |
|---|---|
| Cross-tenant / cross-brand data leakage | Existing fail-closed tenancy + tripwire suites; product filters on both public slug routes (`Hotel.product_hospello` / `.product_askello` at the controller, host-independent so a forged Host header changes nothing); host-scope isolation of cookies (no `domain:` set anywhere — verified) |
| Host-header manipulation | Product checks (above) carry the safety; `config.hosts` allowlist added at rollout (Phase 5) with `/up` excluded |
| IDOR | House pattern kept: hosts reach records only through `Current.account.hotels...` / `current_property.<assoc>` — foreign ids 404 before authorization; cross-account request tests mirror `test/tenancy/cross_tenant_access_test.rb` |
| Public guide enumeration | Askello slugs get a random suffix (`SecureRandom.alphanumeric(6)`); unknown and unpublished guides return the identical 404; guide Q&A throttled per IP |
| Door codes / Wi-Fi on a public URL | Unguessable slug + `X-Robots-Tag: noindex` + meta noindex on every `/g` response (robots.txt deliberately does NOT disallow `/g` — a robots-blocked URL can still be indexed from links and can never see the noindex); host-facing copy states "anyone with the link can read this"; per-property access PIN is the named post-MVP hardening. **Flagged honestly: a shared URL is a shared URL — MVP ships unlisted-not-private, stated to hosts.** |
| Prompt injection via public Q&A | Reuse unchanged: `<guest_message>` sealing, tools-as-only-side-effects with server-validated args, single-tenant prompt construction, 21-shape injection corpus extended with guide-specific shapes |
| AI cost abuse | Per-property daily token budget (existing, enforced in `GenerateReplyJob`), entitlement gate *before* enqueue (free plan never reaches the AI path), Rack::Attack throttle on guide question POSTs, `ai` queue's 2-thread backpressure |
| Rate-limit bypass | Same layered model as Hospello: Rack::Attack (IP) + Rails `rate_limit` (signup, password reset) + budget caps; real-client-IP resolution already handled behind Render's proxy |
| File-upload abuse | Photos reuse the exact `Hotel` attachment validation pattern (content-type + byte-size whitelist, no SVG for photos), synchronous metadata, count cap |
| Stripe webhook spoofing | `Stripe-Signature` verified over `request.raw_post` before anything else (the WhatsApp controller is the copied template); `webhook_events` dedupe; processing job refetches state from Stripe rather than trusting payloads |
| Cross-brand email / URL leakage | Mailer URLs always pass `host:` explicitly, derived from the record's product (never from `Current` in jobs/mailers); per-brand from-address; QR host chosen by product |
| Password-reset oracle / abuse | Uniform "if that address exists…" response, `rate_limit` on request + submit, 30-min expiring `generates_token_for` token, reset request form host-constrained to Askello for MVP |

---

## 4. Recommended target architecture

### The one-paragraph version
Askello properties are **`Hotel` rows with `product: askello`, `plan: essentials`, zero rooms**, owned by a new **`Account`** (the billing + portfolio boundary — *not* a tenant; `Hotel` stays the tenant root). A frozen **`Brand` registry** (config from env hosts) drives naming, hosts, mailer identity, and layout choice; brand is derived from `hotel.product` wherever a tenant exists and from the request host only on public brandless pages. Askello gets three new surfaces — marketing (host-constrained routes), `/host` dashboard (new namespace for the `host` role), and the public guide `/g/:slug` — all reusing the existing models and AI pipeline. The commercial plan (Free/Host/Portfolio) lives on `Account` and is enforced by a single `Askello::Entitlements` object plus the already-proven per-property AI budget; Hospello's `hotels.plan` gating is untouched (every Askello property is permanently `essentials`, which is exactly the Q&A-only concierge shape that already exists and is tested live).

### Brand / product resolution
- `hotels.product` enum `{hospello: 0, askello: 1}`, default 0 NOT NULL — the authoritative axis. `accounts.product` mirrors it for billing-side reads.
- `app/services/brand.rb`: frozen value objects `Brand.hospello` / `Brand.askello` — `name`, `hosts` (primary + optional extras from env, normalized through the existing `AppHost.normalize`), `primary_host` (canonical, used for QR + mailer links), `guest_cookie` (`:hospello_guest` / `:askello_guest`), `mail_from`, `support_email`, `configured?` (false when the host env is unset — the structural kill switch). `Brand.for(product)`, `Brand.for_host(host)`.
- `Current.brand` (new attribute on `app/models/current.rb`, default `Brand.hospello`): set from `hotel.product` in `Staff::BaseController`/`Guest::BaseController`/`Guest::EntriesController` at the same line they set `Current.hotel`; set to `Brand.askello` in `Host::BaseController` and the Askello public controllers; set from request host only in `SessionsController` (the one shared page) and Askello marketing. **Never read from jobs or mailers** — those derive brand from the record they hold (`account.product` / `hotel.product`), because `Current` has no request there.
- Route constraint `app/constraints/askello_host.rb`: `matches?(request) = Brand.askello.configured? && Brand.askello.hosts.include?(request.host)`. Askello marketing/signup routes live inside `constraints(AskelloHost)` declared **above** the existing routes with `root ... as: :askello_root` (first matching root wins). Unset env ⇒ constraint never matches ⇒ Askello is unreachable — rollback is unsetting one env var.
- **No scattered `if askello?`**: the branch points are enumerated and closed — `Brand` registry, `static_rules_for` (one product branch), `Tools` gates (one), `degrade!` locale key (one), `HotelQrCode#path` (one), `KbEntry::PRODUCT_CATEGORIES` (data), layouts chosen per namespace. A grep-style test can pin the allowed `product_askello?` call sites the same way the tenancy grep test pins escape hatches.

### Account and tenant model
- `accounts`: `name`, `product` (int enum), `plan` (int enum `{askello_free: 0, host: 1, portfolio: 2}`), `stripe_customer_id` (unique, nullable), `stripe_subscription_id`, `subscription_status` (string), `current_period_end`, `cancel_at_period_end` (bool default false), `billing_interval` (string), `acquisition` jsonb default `{}` (UTM first-touch), timestamps. **Not tenant-scoped** (no `hotel_id` — no tripwire fires); added to `Retention::Policy` as a keep-while-customer rule for honesty.
- `users.account_id` (nullable FK) + new role `host: 3`. Exactly four verified code points change: `User#hotel_membership_matches_role` (platform_admin → both blank; host → hotel blank + account present; staff/hotel_admin → hotel present + account blank), `User#can_sign_in?` (host branch: `account.present?`), `Authentication#home_url_for` (host → `host_root_url`), and the `TenantDeclarationTest::EXEMPT["User"]` justification text. Everything else **fails closed today**, verified: `Staff::BaseController` 403s hotel-less users, every staff policy's `active_staff?` excludes hosts, `Staff::UsersController#allowed_role` whitelists prevent minting hosts, platform namespace requires platform_admin. MVP = exactly one user per account (no invitations, no in-account roles).
- `hotels.account_id` (nullable FK). **All existing Hospello hotels keep `account_id: nil` — no backfill, no dual-read, no compatibility period needed.** Convergence (giving Hospello hotels accounts) is a post-MVP option, not a prerequisite.

### Property model
- A vacation-rental property = `Hotel(product: askello, plan: essentials, account_id: X, rooms: none)`. Branding columns (`primary_color`, `secondary_color`, logo) reuse verbatim, including the WCAG contrast logic. New columns: `guide_published_at` (nullable — the guide's draft/published state; `/g` 404s while nil), `contact_email` (nullable — the guest-facing "contact host" address; `contact_phone` reused as the host phone). Slug = `name.parameterize + "-" + SecureRandom.alphanumeric(6).downcase` (unguessable + collision/squat-proof; global slug uniqueness holds).
- Guide content = **`KbEntry` reused**, with append-only category enum values for the rental vocabulary (`arrival: 7, wifi: 8, parking: 9, house_rules: 10, checkout: 11, appliances: 12, host_contact: 13, emergency: 14, local_recs: 15, faq: 16`; `local_area`/`transport`/`other` shared where they read right). `KbEntry::PRODUCT_CATEGORIES` map + `Hotel#kb_category_keys` scope what each product's UI offers and a model validation enforces it (fail-closed). This keeps the **entire grounding chain unchanged**: `published_kb_entries` → prompt serialization → citation validation → `cited_kb_entry_ids` audit — a separate `GuideSection` model would have had to re-implement all of it plus tenancy, retention, publish audit, and ordering determinism.
- Guest Q&A = **`GuestSession`/`Conversation`/`Message` reused** via a new anonymous entry path (the WhatsApp precedent: roomless, formless, consent stamped at first question, auto-named, 21-day expiry), cookie `askello_guest`. Channel stays `web`. Everything downstream is inherited: per-conversation reply serialization, coalescing, `client_message_id` dedupe, resync endpoint pattern, budget, breaker, `AiRun` telemetry, unanswered-question logging, 90-day retention.
- Rooms/units: zero Room rows; the optional-units concept is deliberately deferred (the `Room` model exists if ever needed — no new modeling now).

### Routes and namespaces
```
Request surface                          Brand source        Tenant source
──────────────────────────────────────── ─────────────────── ─────────────────────────
askello host: /, /pricing, /sample, ...  request host        none (marketing)
askello host: /signup, /password/*       request host        none → creates Account+Hotel
/host/**            (new namespace)      user role (host)    session-selected property via
                                                             Current.account.hotels (404 on foreign)
/g/:slug            (public guide, any   hotel.product       Hotel.product_askello.find_by!(slug:),
  host — product-checked, noindex)                            published-only
/h/:slug, /guest/** (unchanged)          hotel.product       Hotel.product_hospello.find_by!(slug:) / cookie
/staff/**, /platform/** (unchanged)      hotel.product       Current.user.hotel / none
/webhooks/whatsapp, /webhooks/stripe     n/a                 payload-resolved
```
- Askello **public** controllers (marketing, guide, guide questions) inherit `ActionController::Base` directly (CSRF kept on) — the `Webhooks::WhatsappController` precedent — because `ApplicationController`'s `allow_browser versions: :modern` is an anonymous `before_action` that **cannot be skipped by name**, and a 406 on a conversion funnel or on a guest trying to read a Wi-Fi code is unacceptable. `Host::BaseController` (authenticated) inherits `ApplicationController` normally.
- `/session` (sign-in) stays shared and unconstrained; its page chrome becomes brand-aware via `Current.brand`.

### Shared services (unchanged) vs product-specific
- **Shared, byte-identical:** `Ai::Client`/`Result`/`Concierge`/`GenerateReplyJob` core, circuit breaker, budget/rollup, translator + digit guard, QR generation service, branding helper, Rack::Attack framework, retention machinery, Solid Queue/Cable/Cache, Active Storage, audit logging, seeds framework.
- **Product-branched at named seams:** `PromptBuilder.static_rules_for` (adds `GUIDE_RULES`; `room_unknown_block` suppressed for askello — a guide guest is *always* roomless and must never be asked for a room), `Ai::Tools` (withhold `set_guest_room` for askello at **both** gates — list *and* execute, the house double-gate pattern; per-product wording for `escalate_to_staff`/`log_unanswered_question` descriptions), `GenerateReplyJob#degrade!` (per-product locale key), `HotelQrCode#path` (`/g/` for askello), `ApplicationCable::Connection#find_verified_guest_session` (tries both guest cookie names — without this, guide live updates silently never connect).
- **Product-specific UI:** Askello marketing layout/views; `host` layout + dashboard views (property list, guide builder, questions inbox — *thin, read-only transcript views reusing model scopes*, never the staff views, which render rooms/identity badges/pause-AI/bs-en staff copy); public guide layout (property-branded via the same CSS custom properties). New locale families `askello.en.yml` (marketing+host, en-first) and `askello_guide.{bs,en,de,ar}.yml` (guest-facing chrome), registered in `LocaleFilesTest::FAMILY_LOCALES`.

### Capability / entitlement system
- Two deliberate layers, one seam each:
  - **Operational capability** (per property): `hotels.plan` — stays `essentials` for every Askello property forever; all 13 existing `plan_allows?` call sites behave correctly with zero changes. `Platform::HotelsController#plan` gains a refusal for askello hotels so a platform admin cannot accidentally re-arm request tools against a room-less property.
  - **Commercial entitlement** (per account): `Askello::PlanCatalog` (pure data: property limit 1/1/5, `ai_qa` false/true/true, daily token budget 0/N/N, generation allowance, duplication portfolio-only, Stripe price env keys; `fetch`-style so unknown plans raise) + `Askello::Entitlements` — the single predicate object every Askello gate asks (property create, ask-box render, question POST, duplication). Mirrors the `plan_allows?` philosophy; no conditionals scattered elsewhere.
- Enforcement is server-side at the action, not just hidden buttons: property-limit on `Host::PropertiesController#create`, AI gate on the guide question POST (403 before `post_guest_message!`, so the Free plan **never reaches the degrade path** — budget 0 stays as defense in depth), generation allowance in the generation service.

### Billing separation
- `stripe` gem; Askello-only Stripe **products/prices** configured by env price IDs — nothing Hospello-related in Stripe at all. `Host::CheckoutsController` (Stripe Checkout session; success/cancel URLs built with the explicit Askello host), `Host::BillingPortalController` (Customer Portal for card/plan/cancel — Stripe hosts the hard UI). Webhook: `Webhooks::StripeController` mirroring the WhatsApp controller *exactly* (raw-body signature first, `webhook_events` insert `ON CONFLICT DO NOTHING` with new enum value `provider: stripe`, enqueue `Billing::ProcessStripeEventJob` on `critical`, fast 200). The job is idempotent and out-of-order-safe **by refetching the subscription from the Stripe API** rather than trusting event payload ordering; it resolves the account by `stripe_customer_id`, updates plan/status/period in one transaction, then propagates `ai_daily_token_budget` to the account's hotels from the catalog. Downgrades **never destroy data**: beyond-limit properties get unpublished (newest-first kept), flagged on the dashboard.

### Email and URL handling
- First mailers in the codebase: SMTP via generic env (`SMTP_ADDRESS/PORT/USERNAME/PASSWORD/DOMAIN` — Resend's SMTP interface recommended, but nothing Resend-specific in code), configured in `production.rb` only when set. `AskelloMailer` (password reset, welcome); every URL passes `host:` explicitly from `Brand.for(record.product).primary_host` — `action_mailer.default_url_options` stays pointed at the Hospello host and is never made dynamic (global state; the first future Hospello mailer would inherit the hack).
- Password reset via Rails 8.1's `generates_token_for :password_reset, expires_in: 30.minutes` — **no new table**. Routes host-constrained to Askello for MVP; uniform non-oracle responses; rate-limited.
- QR/share URLs: `HotelQrCode.new(hotel, host: Brand.for(hotel.product).primary_host)`.

### Analytics separation
- First-party `product_events` table (name, product, `visitor_token`, nullable `account_id`/`hotel_id`, `utm` jsonb, `metadata` jsonb, `occurred_at`) — **not tenant-scoped** (pre-signup events have no tenant; registered in `TenantDeclarationTest::EXEMPT` with a `for_hotel` scope, plus a 365-day rule in `Retention::Policy` and a purge clause — both tripwires fire otherwise, by design). `Askello::Track.record!` service; server-side emission covers the whole required funnel (`landing_view` … `first_guest_question`) because every funnel point is a server-rendered request — **no client-side beacon, no third-party tag, CSP untouched** for MVP. UTM first-touch captured into a signed cookie on marketing pages, copied to `accounts.acquisition` at signup. Hospello emits nothing — its analytics stay `Analytics::HotelReport`.

### Deployment topology
- **Unchanged:** one Render web service, one Postgres, Solid Queue in Puma. Askello domains added as additional custom domains on the same service (Render handles TLS). `render.yaml` gains the new env vars. **Launch precondition: bump `plan: free` → `starter`** — a self-serve funnel cannot ride an instance that sleeps (cold start ≈ 60s bounce; a sleeping instance also stops webhook/job processing), and once paid, `db:migrate` moves to `preDeployCommand` per the file's own documented path.

### Why this is the safest incremental architecture (tradeoffs)
- **Reuse over parallel build:** every AI-safety property Hospello paid for (grounding, sealing, injection corpus, budget, breaker, citation audit, unanswered-question loop) transfers to Askello at zero marginal cost *because* the same code runs. A parallel "guide engine" would restart that debt from zero.
- **`Account` addition over `Hotel` rename:** the rename would touch 18 FK'd tables, every policy/controller/test, and the printed-QR route — maximal risk, zero customer value. The nullable `account_id`/`product` columns are invisible to every existing code path (verified: defaults + nullability mean the 1,301 tests run unchanged).
- **Two-layer entitlements over one unified engine:** unifying Hospello's plan enum with Askello's commercial plans would force changes into 13 working call sites and the platform admin UI for no MVP benefit. The cost — two small gating vocabularies — is explicit and contained; convergence remains possible later by mapping `hotels.plan` onto account plans.
- **Product-checked slug routes over host-checked:** host checks break on the shared onrender.com host and under Host-header forgery; product checks hold everywhere and make brand isolation a *data* property, not a *network* property.
- **Accepted costs:** `Hotel`/`hotel_id` naming appears in Askello's internals (invisible to customers; a documented vocabulary map in code comments); the staff namespace contains screens Askello never uses (dead weight, not risk — unreachable for hosts by construction); one more rules variant to keep byte-stable.

---

## 5. Phased implementation plan

> Conventions inherited by every phase: strictly additive migrations (build-script migration window — old code briefly serves against the new schema); every boundary test proven able to fail (break-the-code, watch red, restore); `bin/rails test` + `test:system` + rubocop + brakeman green before every push; HANDOVER.md updated in the same commit; no secrets committed; every new env var lands in `render.yaml` + `.env.example` + README in the same commit as its first reader.

### Phase 0 — Guardrails and prerequisite refactoring
- **Objective:** create the product axis and close the doors *before* any Askello surface exists, leaving Hospello byte-identical.
- **Existing files changed:** `app/models/hotel.rb` (product enum), `app/models/current.rb` (`attribute :brand`), `app/controllers/guest/entries_controller.rb` (`Hotel.product_hospello.find_by!`), `app/controllers/platform/hotels_controller.rb` (`#plan` refuses askello), `app/services/hotel_qr_code.rb` (`#path` branches by product), `app/views/staff/kb_entries/index.html.erb` + form select (iterate `Hotel#kb_category_keys`), `app/helpers/staff_helper.rb` (category helpers), `render.yaml`/`.env.example` (document `ASKELLO_HOST` reserved).
- **New files:** `app/services/brand.rb`; `db/migrate/*_add_product_to_hotels.rb`; `test/services/brand_test.rb`.
- **Migrations:** `add_column :hotels, :product, :integer, default: 0, null: false`.
- **Jobs / external deps:** none.
- **Tests:** product enum defaults; `/h/:slug` 404s an askello fixture hotel (break the filter, watch red); platform plan-change refusal for askello; `HotelQrCode#path` per product; KB category chips unchanged for hospello. One new `hotels.yml` fixture (askello property) — existing fixtures untouched.
- **Security:** the product filter on `/h` is the first brand-isolation boundary — break-tested.
- **Deployment order:** migrate + deploy in one push; nothing user-visible changes.
- **Acceptance:** full suite green; production behavior byte-identical; an askello-product hotel created in console is unreachable via `/h` and cannot have its plan changed.
- **Effort:** S (2–3 engineer-days). **Depends on:** nothing.

### Phase 1 — Askello brand, domains, and marketing funnel
- **Objective:** Askello exists publicly — landing, pricing, sample guide, FAQ, legal — on its own domain, with UTM capture, while the default host stays untouched.
- **Existing files changed:** `config/routes.rb` (constraints block at top), `app/views/sessions/new.html.erb` + `layouts/application.html.erb` (brand-aware chrome via `Current.brand`), `app/controllers/sessions_controller.rb` (small `SetsBrandFromHost` concern), `render.yaml`.
- **New files:** `app/constraints/askello_host.rb`; `app/controllers/askello/base_controller.rb` (**inherits `ActionController::Base`**, CSRF on, sets brand, layout `askello`); `app/controllers/askello/pages_controller.rb` (landing, pricing, sample, faq, privacy, terms); `app/views/layouts/askello.html.erb` + page views (distinct visual identity; SEO meta — title/description/OG per page; primary CTA "Create my free guide", secondary "View sample guide"; copy uses "AI guest guide for vacation rentals", never "Airbnb" in branding); UTM/visitor-token cookie concern; `config/locales/askello.en.yml`; sample guide = a hardcoded demo property page (static, no DB dependency).
- **Migrations / jobs:** none.
- **Config/env:** `ASKELLO_HOST` (bare host; unset = Askello unreachable), optional `ASKELLO_EXTRA_HOSTS` (comma list, e.g. `www.`).
- **External dependencies:** DNS + Render custom domain attach (TLS automatic).
- **Tests:** integration with `host!` — askello host root renders landing while default host still renders sign-in (break the constraint, watch both directions); pricing/legal render; old-browser UA gets **200** on marketing (proving the `allow_browser` bypass, not assuming it); UTM cookie set + first-touch preserved; `FAMILY_LOCALES` gains the family.
- **Security:** marketing pages are static renders (no user input); cookie is signed; legal pages marked "PILOT DRAFT — legal review required" (house pattern, test-protected).
- **Deployment order:** deploy with `ASKELLO_HOST` unset → verify Hospello → set env + attach domain → verify both hosts.
- **Acceptance:** Askello domain serves the funnel; Hospello domain byte-identical; Lighthouse-fast landing (no JS needed beyond Turbo).
- **Effort:** M (4–6 days). **Depends on:** Phase 0.

### Phase 2 — Self-service onboarding and guide builder
- **Objective:** signup → account+property → paste listing → AI-drafted editable guide, in under 5 minutes, with password reset and the first mailer.
- **Existing files changed:** `app/models/user.rb` (role `host: 3`, validation matrix, `can_sign_in?`, `generates_token_for :password_reset`), `app/models/hotel.rb` (`belongs_to :account, optional: true`, `kb_category_keys`), `app/models/kb_entry.rb` (new enum values + product-scoped validation), `app/models/ai_run.rb` (kind `generation: 2`), `app/controllers/concerns/authentication.rb` (`home_url_for` host branch), `config/environments/production.rb` (SMTP-when-set block), `config/routes.rb`, `config/initializers/rack_attack.rb` (signup + password-reset throttles), `test/tenancy/tenant_declaration_test.rb` (EXEMPT["User"] comment), `app/services/retention/policy.rb` (accounts rule), locale files (`staff.{bs,en}.yml` gain the new category keys together).
- **New files:** migrations (below); `app/models/account.rb`; `app/controllers/askello/registrations_controller.rb` (one transaction: Account←UTM + User(host) + Hotel(product: askello, plan: essentials, random-suffix slug, budget from catalog); gated by `ASKELLO_SIGNUPS_ENABLED`; **no `HotelDefaults.apply!`**); `app/controllers/askello/passwords_controller.rb`; `app/controllers/host/base_controller.rb` (require host role; `Current.account`; property selection validated through `Current.account.hotels` → `ActsAsTenant.with_tenant`); `Host::PropertiesController`, `Host::GuideController` (builder: generate / section list / publish–unpublish via `guide_published_at` + entry publishing), `Host::GuideSectionsController` (KbEntry CRUD within the askello category list, own views), `Host::PhotosController`; `app/services/askello/guide_generation.rb` (one `Ai::Client#chat`, single forced tool `create_guide_sections` returning `{category, title, content}[]`; server-side re-validation: category whitelist, ≤2000-char splitting, title dedup; creates **draft** entries only; writes `AiRun(kind: :generation)`; allowance from entitlements — *not* the chat budget, so Free's budget-0 cannot block onboarding); `app/jobs/askello/generate_guide_job.rb` (`:ai` queue, per-hotel concurrency limit, Turbo refresh; failure degrades to "add sections by hand" with the checklist — no dead ends); `app/mailers/askello_mailer.rb` + views (explicit `host:`); `app/policies/host/*` (role questions only); host layout + views incl. the guided checklist (the required topics = the askello category list itself, rendered as empty-state prompts per category — same pattern as `StaffHelper::KB_STARTERS`); `has_many_attached :photos` on Hotel with the existing validation pattern (count ≤ 10, ≤ 5MB each, no SVG); fixtures `accounts.yml` + host user + linked property.
- **Migrations (ordered, each independently shippable):** (1) `CreateAccounts` (columns as §4); (2) `AddAccountToUsersAndHotels` (nullable FKs); (3) `AddGuideFieldsToHotels` (`guide_published_at:datetime`, `contact_email:string`).
- **Jobs:** `Askello::GenerateGuideJob` (`:ai`).
- **Config/env:** `ASKELLO_SIGNUPS_ENABLED`, `SMTP_ADDRESS/PORT/USERNAME/PASSWORD/DOMAIN`, `ASKELLO_MAIL_FROM` — all inert when unset.
- **External dependencies:** SMTP provider account (Resend recommended) + SPF/DKIM on the Askello domain.
- **Tests:** User validation matrix (4 roles × hotel/account presence — break the validation, watch); `can_sign_in?` host branch; registration transaction integrity (failed hotel save leaves no orphan account/user), disabled-flag, duplicate email re-render, throttle 429; generation with FakeClaude (tool-call splitting, >2000-char split, dedup, **drafts only** — flip to `published: true` and watch the unpublished-by-default test fail); AiRun generation kind rolls into AiUsageDay; host cannot reach `/staff`//`platform` and vice versa (403s); host of account A 404s on account B's property (cross-account suite mirroring the tenancy house tests); password-reset token expiry + non-oracle response; mailer URLs carry the Askello host (literal assertion).
- **Security:** signup rate-limited; reset non-oracle; photos content-type/size whitelisted; generation input capped (e.g. 20k chars) before it reaches the model.
- **Deployment order:** migrations → deploy with signups disabled → staging smoke → enable flag.
- **Acceptance:** on staging: signup → paste → generated draft guide → edited → checklist shows gaps, all inside 5 minutes; Hospello suite green throughout.
- **Effort:** L (9–12 days). **Depends on:** Phases 0–1 (host-constrained signup routes).

### Phase 3 — Public guest guide, AI Q&A, QR, and analytics
- **Objective:** the published guide is live on a shareable URL/QR; guests browse, search, and ask; hosts see questions and gaps; the funnel is measured.
- **Existing files changed:** `app/services/ai/prompt_builder.rb` (`GUIDE_RULES`; product branch in `static_rules_for`; suppress `room_unknown_block` for askello; `contact_email`/host lines in the **cached** hotel block), `app/services/ai/tools.rb` (product double-gate on `set_guest_room`; per-product tool descriptions), `app/jobs/ai/generate_reply_job.rb` (per-product degraded key), `config/locales/degraded.{bs,en,de,ar}.yml` (+`host_will_reply`, all four at once), `app/channels/application_cable/connection.rb` (try both guest cookie names), `config/initializers/rack_attack.rb` (guide-question throttle), `test/i18n/locale_files_test.rb` (`FAMILY_LOCALES` + `askello_guide`), `test/tenancy/tenant_declaration_test.rb` (EXEMPT `ProductEvent` with justification + `for_hotel` scope), `app/services/retention/policy.rb` + purge job (product_events, 365d), `config/routes.rb`, `db/seeds/demo.rb` (optional askello sample property).
- **New files:** `db/migrate/*_create_product_events.rb`; `app/models/product_event.rb`; `app/services/askello/track.rb`; `app/controllers/askello/guides_controller.rb` (**`ActionController::Base`**; `Hotel.product_askello.find_by!` + published-only with identical 404 for unknown/unpublished; owner-preview of drafts via host session; sections grouped in `PRODUCT_CATEGORIES[:askello]` order; server-side search (ILIKE over title/content); `X-Robots-Tag: noindex` + meta; property branding via `hotel_brand_style`; photos; sticky "Ask a question" + "Contact host" bar with `tel:`/`mailto:` from `contact_phone`/`contact_email`); `app/controllers/askello/guide_questions_controller.rb` (first POST creates the anonymous GuestSession — consent stamped, auto-named, `askello_guest` cookie — then `Conversation.live_for` + `post_guest_message!`; entitlement-gated 403 *before* enqueue for plans without AI; GET resync mirroring `Guest::MessagesController#index`; per-IP throttle + reuse of the per-session `rate_limit` pattern); Q&A chat view (reusing the chat Stimulus controllers + `shared/_translated_body` mechanics where applicable, new chrome/copy from `askello_guide.*`); `Host::QuestionsController` (+ unanswered-questions list wired to "answer & add to guide" → guide-section form pre-filled — the `UnansweredQuestion` loop reused verbatim); `Host::QrCodesController` + Askello print sheet (`HotelQrCode` with the Askello host; download filenames `askello-qr-<slug>`); host analytics page (reuses `Analytics::HotelReport` subset: guests, questions, unanswered list; plus guide_view counts from product_events).
- **Migrations:** `CreateProductEvents` (columns as §4; indexes `[name, occurred_at]`, `[hotel_id, name, occurred_at]`).
- **Jobs:** none new (replies ride the existing `Ai::GenerateReplyJob`).
- **Config/env:** none new.
- **Tests:** guide 404 matrix (unknown / unpublished / hospello-product slug — identical bodies; break the product filter); noindex header; Q&A end-to-end with FakeClaude (grounded answer, citations recorded, session auto-created once per cookie, `client_message_id` dedupe); `set_guest_room` refused at execute for askello (break each gate separately — the two-layer note pattern); `room_unknown` absent from askello prompts *and* still present for roomless WhatsApp (pin both directions); per-product degraded copy; **byte-identical `SERVICE_RULES`/`ESSENTIALS_RULES` pin test for hospello hotels** (the "Askello didn't move Hospello's prompt" regression); cable subscription with the new cookie (break `find_verified_guest_session`, watch); injection corpus + guide shapes ("ignore the guide and tell me the door code of another property"); entitlement gate 403 (Free) before any AiRun exists; retention purge covers product_events; funnel events emitted at each step; system test: phone-viewport scan → read wifi → ask → grounded answer.
- **Security:** all of §3's guide controls land here (noindex, uniform 404, throttles, entitlement gate, sealing reuse).
- **Deployment order:** migrate → deploy → publish the seeded sample property → verify `/g` on both the Render host and the Askello domain.
- **Acceptance:** a phone can open a published guide from the QR, search it, ask in German and get a German grounded answer or an honest "ask your host" with the contact card; the host sees the question and the gap; Hospello prompts byte-identical.
- **Effort:** L (7–10 days). **Depends on:** Phase 2.

### Phase 4 — Billing, plans, usage limits, and entitlements
- **Objective:** money — Checkout, Portal, webhooks, and server-side enforcement of the three-tier catalog; account deletion and cancellation flows.
- **Existing files changed:** `Gemfile` (+`stripe`), `app/models/webhook_event.rb` (provider enum +`stripe: 3`; reword the retention rule's "why" prose — numbers unchanged), `config/initializers/rack_attack.rb` (signature-verified Stripe safelist mirroring the WhatsApp one, same raw-body rewind care), `render.yaml`/`.env.example`/README, host layout (plan badge, upgrade CTAs, limit banners), `Host::PropertiesController` (limit enforcement), guide question controller (entitlement source becomes the live subscription state).
- **New files:** `app/services/askello/plan_catalog.rb` (data: limits, budgets, allowances, price-ID env keys; monthly + annual per paid tier); `app/services/askello/entitlements.rb`; `app/controllers/host/checkouts_controller.rb`, `host/billing_portals_controller.rb`, `host/accounts_controller.rb` (cancellation → Portal; **account deletion**: confirm-by-naming-what-dies (the `GuestErasure` house pattern), cancel the Stripe subscription via API, destroy hotels (DB cascades wipe tenant children), sessions, user, account, audit-log the event); `app/controllers/webhooks/stripe_controller.rb` (the WhatsApp template verbatim: `ActionController::Base`, CSRF skip, `Stripe::Webhook.construct_event` over `request.raw_post`, `webhook_events` `insert_all unique_by:`, enqueue on `:critical`, 200 fast, malformed-but-signed → Sentry + 200); `app/jobs/billing/process_stripe_event_job.rb` (idempotent; refetches subscription state from Stripe; maps price ID → plan via catalog; one transaction on the account; propagates per-hotel `ai_daily_token_budget` inside per-hotel `with_tenant`; downgrade unpublishes-never-deletes; handles `checkout.session.completed`, `customer.subscription.updated/deleted`, `invoice.payment_failed` → `subscription_status: past_due` → entitlements degrade to Free until recovery); `Host::PropertyDuplicationsController` (Portfolio: copy property attrs + KbEntries **as drafts**); fixtures + `test/support` Stripe event fixtures (hand-built JSON, HMAC computed with a test secret — WebMock stubs the refetch; **no network, no VCR**, house rule).
- **Migrations:** none (accounts table shipped in Phase 2).
- **Jobs:** `Billing::ProcessStripeEventJob` (`:critical`).
- **Config/env:** `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_HOST_MONTHLY`, `STRIPE_PRICE_HOST_ANNUAL`, `STRIPE_PRICE_PORTFOLIO_MONTHLY`, `STRIPE_PRICE_PORTFOLIO_ANNUAL` — all inert when unset (billing screens render "not configured"; webhook 401s).
- **External dependencies:** Stripe account; Askello products/prices created in the Stripe dashboard (test + live); webhook endpoint registered.
- **Tests:** signature accept/reject (hand-computed `t=...,v1=...`); replay of one event id → job runs, state converges (idempotency by refetch — assert one final state, not one job); out-of-order (older update after newer → WebMock refetch returns current → account correct); budget propagation (break it, watch the entitlement test fail); property-limit enforced against a crafted POST (not just a hidden button); downgrade unpublishes newest-first and deletes nothing; failed payment degrades entitlements and recovery restores them; cancellation keeps service until `current_period_end`; account deletion destroys exactly the named graph and audit-logs (fixture-id capture *before* the call — the house RecordNotFound trap); Rack::Attack safelist proven with a temporarily-registered throttle (the WhatsApp test pattern, since no real throttle matches `/webhooks/stripe`).
- **Security:** webhook spoofing, replay, and out-of-order per §3; price IDs only ever from env; no card data touches the app (Checkout-hosted).
- **Deployment order:** deploy with Stripe env unset → configure Stripe test mode on staging → end-to-end with Stripe CLI/test clocks → set live keys.
- **Acceptance:** Free→Host checkout turns the ask box on within seconds of the webhook, no redeploy; downgrade/cancel/failed-payment behave as specified; Hospello untouched.
- **Effort:** L (6–9 days). **Depends on:** Phases 2–3 (entitlements gate real surfaces).

### Phase 5 — Production rollout, monitoring, and optimization
- **Objective:** launch safely, observably, and reversibly.
- **Existing files changed:** `render.yaml` (**`plan: starter`**, `preDeployCommand: bundle exec rails db:migrate`, all env vars final), `config/environments/production.rb` (`config.hosts` allowlist: APP_HOST, Askello hosts, `.onrender.com`, `/up` excluded — only after both domains are verified live), `config/initializers/sentry.rb` (tag events with product), `platform/hotels` index/show (product badge + filter — platform admins now see Askello properties, labeled), `db/seeds/demo.rb` (guarded Askello demo property, same idempotency + foreign-hotel refusal patterns), `docs/runbook.md` (Stripe key rotation, webhook replay — safe because of dedupe; domain/DNS/SPF-DKIM setup; Askello incident basics), README (Askello section), HANDOVER.md.
- **New files:** smoke-test checklist doc (`docs/askello-launch-checklist.md`); optionally a tiny platform funnel page over `product_events` (else SQL in the runbook).
- **Migrations/jobs:** none.
- **Config/env:** finalize; document every var.
- **Tests:** the manual QA matrix (below, under §9); full regression suite; `LIVE_AI=1` smoke against a real key now exercises GUIDE_RULES too (extend `live_essentials_test` pattern with one guide scenario).
- **Security:** hosts allowlist; Sentry product tagging so Askello noise never masks a Hospello page.
- **Deployment order:** §9's step-by-step.
- **Acceptance:** limited beta (5–10 real hosts) through the full journey; both brands' smoke tests green; monitoring answering "is Askello up" separately from "is Hospello up".
- **Effort:** M (3–5 days). **Depends on:** all previous.

---

## 6. Data migration and backward compatibility

- **Existing Hospello records:** untouched. `hotels.product` arrives with `default: 0 (hospello), NOT NULL` — on this table size the default backfills instantly and invisibly; `account_id` stays `nil` for every existing hotel; no row is rewritten, no dual-read, no compatibility window needed. Existing fixtures and all 1,301 tests run unchanged (new columns defaulted/nullable; new tables get new fixtures).
- **New Askello accounts:** born complete — `Account` + `User(host)` + `Hotel(product: askello, plan: essentials)` created in one transaction at signup; no state ever migrates between products.
- **Product-type assignment:** by construction, never by inference — `/h` serves only `product_hospello`, `/g` only `product_askello`, platform hotel creation stays hospello-default, Askello registration writes askello explicitly. No backfill job exists because no ambiguous rows can exist.
- **Property/room compatibility:** Askello properties have zero rooms; every room-dependent path is already optional-safe (WhatsApp precedent) or plan/product-gated. `Room` model unchanged.
- **Enum discipline (the one real hazard):** every enum change is **append-only integers** — KbEntry categories (prompt-visible), `AiRun.kind` (feeds the AiUsageDay unique index), `WebhookEvent.provider`, `User.role`, `Account.plan`. Renumbering would corrupt history; the plan never renumbers, and removal is allowed only after verifying no rows carry the value.
- **Safe deployment order (every phase):** migration commit deploys first (or together — the build script migrates before the new code boots, and old code ignores additive columns during the window), then the code that reads it; env vars set before the flag that activates their reader; `ASKELLO_HOST` unset until each phase's smoke test passes.
- **Rollback:** every migration is independently reversible (`remove_column`/`drop_table`); code-level rollback is unsetting `ASKELLO_HOST` (+ `ASKELLO_SIGNUPS_ENABLED`), which makes every Askello route unmatched while Hospello continues untouched — no data is destroyed by rolling back, and re-enabling later picks up where it left off. **No destructive migration exists anywhere in this plan.**

---

## 7. MVP versus later roadmap

**Required for Askello MVP** (phases 0–5): product axis + brand registry; marketing site (landing, pricing, sample, FAQ, legal) with UTM capture; self-service signup, password reset, first mailer/SMTP; account + host role; property CRUD with limits; guided checklist onboarding; paste-listing AI guide generation into editable draft sections; photos; colors/logo branding; draft→preview→publish; public mobile guide with search, grounded AI Q&A (guest's language), honest unknown-fallback, contact-host bar; QR + print sheet; unanswered-question reporting; host analytics overview; funnel events; Stripe Checkout/Portal/webhooks; three-tier catalog with server-side entitlements (property counts, AI budgets, feature gates); cancellation + account deletion; Askello demo/seed property; both-brand smoke tests + monitoring.

**Post-MVP opportunities** (explicitly out of the critical path): team members / multi-user accounts with invitations; per-property access PIN for sensitive guide content; guide content translation (paid "translations" beyond AI answering in-language — the `Ai::Translator` seam is ready); WhatsApp channel for Askello (the whole port exists); PMS/channel-manager/Airbnb API or inbox integrations; iCal import; paid guest upsells (early check-in, activities); local marketplace; native apps; smart locks / reservation-aware door codes; fully white-label custom domains per host; Hospello-hotel Account convergence (backfill accounts for hotels, unify billing); annual invoicing/VAT handling beyond Stripe Tax defaults; richer guide blocks (video, maps embeds); public guide PWA; extra-property add-ons beyond Portfolio; a third-party analytics tag (CSP change) if product analytics outgrow first-party events; readiness-checklist screen for Hospello (still open from Slice 7).

---

## 8. Critical decisions

1. **Same repository?** Yes. The audit found no isolation-, compliance-, or team-boundary reason to split; the shared AI/tenancy substrate is the whole value.
2. **Same Rails application?** Yes. Brand separation is achieved by data (`product`), routes (namespaces + host constraint), and config (Brand registry) — not process boundaries. Every "second app" benefit on offer here is available as a namespace at a fraction of the risk.
3. **Same Render service initially?** Yes — with the paid-tier bump (`starter`) as a launch precondition (a sleeping free instance is a dead funnel and a stopped queue). The already-documented split path (separate worker) stays available and unneeded at MVP scale.
4. **Same PostgreSQL database initially?** Yes. Tenancy fails closed and is tripwire-tested; Askello adds two small tables and three columns. The documented scale path (bigger DB plan → worker split) is unchanged.
5. **Separated from day one:** domains/hosts; brand registry entries; guest cookie names (`askello_guest`); mailer identity + explicit hosts; Stripe products/prices/webhook (Askello-only); locale families; marketing SEO surface (Hospello stays unindexed); funnel analytics (product_events, Hospello emits none); Sentry product tag; QR path/host and filenames; degraded-mode copy.
6. **Safely shared:** tenancy machinery and its tests; `Hotel` as tenant root; `KbEntry` corpus + grounding chain; `GuestSession`/`Conversation`/`Message` pipeline; `Ai::*` seam, budget, breaker, telemetry; QR service; branding/CSS-custom-property system; Rack::Attack; Active Storage/R2; Solid Queue/Cable/Cache; retention + erasure; audit logs; `webhook_events` idempotency store; CI + deploy pipeline.
7. **Highest-risk technical assumption:** that the anonymous public Q&A path (no name, no room, no form) composes with the existing Conversation pipeline without weakening any Hospello invariant. Mitigations: the WhatsApp roomless precedent already in production; the four named adjustment points (cable cookie, degraded copy, entitlement pre-gate, GUIDE_RULES/room-suppression) each carry break-tested coverage; the byte-identical Hospello prompt pin test. Second-highest: one 512MB instance absorbing marketing traffic + generation load — mitigated by the starter bump, `ai`-queue backpressure, and capped generation `max_tokens`.
8. **Implement first:** Phase 0 (product axis + brand registry + the two public-route product filters). It is small, invisible to customers, and every later phase hangs off it.
9. **Deliberately NOT refactored yet:** no rename of `Hotel`/`Room`/`hotel_admin`; no Account backfill for Hospello hotels; no unification of `hotels.plan` with Askello's commercial plans; no touching the 13 `plan_allows?` call sites; no dynamic `default_url_options`; no changes to the translation delivery pipeline, WhatsApp stack, reception inbox, or retention windows; no `allow_browser` policy change for Hospello surfaces; no PWA; no Rails `load_defaults` bump inside this project (schedule separately).

---

## 9. Rollout and rollback plan

**Gating model:** structural, two levels — `ASKELLO_HOST` unset ⇒ every Askello route unmatched (brand-level kill switch); `ASKELLO_SIGNUPS_ENABLED` ⇒ registration specifically (funnel kill switch that leaves existing customers working). Stripe env unset ⇒ billing screens inert. No separate feature-flag system is warranted.

1. **Per-phase staging verification** on a second Render Blueprint (or the same service pre-domain, using the `.onrender.com` host with `ASKELLO_EXTRA_HOSTS`): each phase's acceptance criteria + full suite green + the Hospello byte-identical checks (prompt pin test, `/h` behavior, staff/platform screens).
2. **Database migration order:** always additive, always deployable ahead of their readers (§6); on free tier they run in the build window — before Phase 5 flips to `starter`, keep each migration+code pair in one deploy and small.
3. **Domain configuration:** DNS → Render custom domains (marketing + optional www) → TLS verified → `ASKELLO_HOST`/`ASKELLO_EXTRA_HOSTS` set → landing verified on the real domain → SPF/DKIM for the mail domain verified before the first reset email.
4. **Stripe configuration:** test-mode products/prices + webhook on staging (Stripe CLI + test clocks for renewal/failed-payment paths) → live products/prices → live webhook → one real €-cent-level end-to-end (own card) → refund.
5. **Seed/demo property:** the guarded Askello sample property seeded (`SEED_DEMO=1` path) and **published** — it doubles as the marketing "View sample guide" target and the permanent smoke-test object.
6. **Internal testing — the manual QA matrix:**
   | Surface | Browsers | States |
   |---|---|---|
   | Hospello domain: `/`, `/h/<slug>`, guest chat, `/staff`, `/platform` | Desktop Chrome/Firefox + iPhone Safari + Android Chrome | signed-out, staff, hotel_admin, platform_admin |
   | Askello marketing domain: landing, pricing, sample, signup | same four | signed-out, signed-in host |
   | Askello `/host` app: onboarding, builder, publish, QR, billing | desktop + mobile | free, paid (Host), Portfolio, past_due, cancelled |
   | Public guide `/g/<slug>` | iPhone Safari + Android Chrome (primary), desktop | published, unpublished (404), free plan (no ask box), paid (Q&A), each of bs/en/de/ar chrome |
   | Cross-checks | — | Hospello slug on `/g` → 404; Askello slug on `/h` → 404; host on `/staff` → 403; staff on `/host` → 403 |
7. **Limited beta:** signups enabled, unannounced; 5–10 real hosts recruited directly; watch Sentry (product-tagged), `product_events` funnel, `AiUsageDay` costs, queue health; fix; only then announce.
8. **Production activation:** announce/marketing live; monitor the same four dashboards daily for the first weeks.
9. **Monitoring:** existing heartbeat + QueueHealth cover the shared substrate; add Sentry alert rule scoped to `product:askello`; watch Stripe webhook delivery dashboard (Stripe retries failures for days — the dedupe makes replays safe); weekly funnel SQL from `product_events` until a dashboard earns its keep.
10. **Rollback triggers and steps:** any cross-brand or cross-tenant leak (immediate: unset `ASKELLO_HOST`, investigate — Hospello unaffected); AI cost anomaly (lower catalog budgets or disable `ai_qa` in the catalog — config deploy, no data change); billing incongruence (disable signups, webhooks keep reconciling — state converges by refetch); Hospello regression traced to a shared seam (revert that commit; every shared-seam change carries the Hospello pin tests precisely so this is detectable in CI, not in production). Nothing in the rollback path deletes or rewrites data.

---

## 10. Open questions

Only what code inspection cannot settle. Each ships with a recommended default so implementation never blocks.

1. **Free plan: tiny AI allowance or none?** *Matters because* it is the conversion mechanism ("demonstrate value") vs. the abuse surface (anonymous public endpoint spending tokens). *Default:* none at MVP — Free gets the guide + QR + search; the ask box renders as a locked teaser ("Enable AI answers — €9.90/mo"); this needs zero new metering (budget 0 semantics exist) and makes cost abuse structurally impossible on unpaid properties. *If instead "small allowance":* add a per-property monthly question counter + a "trial questions" catalog entry (~1 extra day, new counter table or reuse `AiUsageDay` reads), and the entitlement gate checks it.
2. **Do guide-generation tokens draw on the same daily budget as guest Q&A?** *Matters because* `AiRun.tokens_used_today` sums all kinds — a paid host regenerating their guide twice could budget-block their guests' Q&A for the day. *Default:* keep one shared budget for MVP (simplest, still bounded) but size paid budgets with generation headroom, and meter generation count by entitlement allowance anyway. *If separated:* `budget_exhausted_for?` gains a kind filter — a semantic change to a proven method, needing its own deliberate test round.
3. **Askello guest-chrome languages at launch: en-only or the existing four?** *Matters because* the structural locale test makes each family's language set a commitment, and machine-translated chrome without native review is a known caveat. *Default:* ship `askello_guide` in all four existing locales (reusing reviewed vocabulary where it exists; AI answers are language-universal regardless), marketing/host UI en-only. *If en-only guide chrome:* `FAMILY_LOCALES` entry is just `[en]` — smaller, expand later.
4. **SMTP provider = Resend?** *Matters because* SPF/DKIM setup is per-provider and deliverability of reset emails is launch-critical. *Default:* Resend (already the plan-of-record choice for Hospello ops mail); code stays provider-generic (`SMTP_*`). Changing providers = changing env vars.
5. **Do Hospello staff also get password reset once the mailer exists?** *Matters because* it changes Hospello's documented "no email, assisted onboarding" security posture. *Default:* no — reset routes host-constrained to Askello at MVP; revisit for Hospello deliberately (it is a one-line constraint removal plus a product decision, not engineering).
6. **Annual prices in the MVP checkout?** *Matters because* it doubles the Stripe price surface (4 price IDs) but the stated pricing includes €79/€249 annual. *Default:* yes — Stripe Checkout handles interval choice cheaply; the catalog already carries both env keys.
7. **One Askello host or marketing/app split (`askello.com` + `app.askello.com`)?** *Matters because* cookies, `config.hosts`, QR canonical host, and the constraint all read the host list. *Default:* one host for MVP (marketing + `/host` + `/g` on the same domain) — the Brand registry's host-list design (`ASKELLO_EXTRA_HOSTS`) means adding an app subdomain later is configuration plus one canonical-host decision, not rework. No production domain is hardcoded anywhere.
8. **Trial vs. freemium?** *Matters because* it shapes checkout copy and whether `trial_ends_at` handling exists. *Default:* freemium only (the Free plan *is* the trial; no Stripe trial periods, no clock logic). *If a paid-tier trial is wanted:* Stripe `trial_period_days` on Checkout + one status branch (`trialing` treated as active) — small, additive.
9. **Guide access PIN in MVP?** *Matters because* door codes on an unlisted-but-shareable URL is the plan's flagged residual exposure. *Default:* post-MVP fast-follow; MVP ships unguessable slug + noindex + honest host-facing copy. *If pulled into MVP:* +2–3 days (hashed per-property PIN, cookie after entry, entry screen in four locales, rate limiting).

---

## Closing

### 1. Recommended MVP scope
Phases 0–5 exactly as specified: Askello brand/domain/marketing with UTM-attributed funnel events; fully self-service signup → property → AI-drafted editable guide → published mobile guide with grounded Q&A, QR, and contact-host fallback; three-tier Stripe billing with server-side entitlements; both-brand regression protection throughout. Everything in §7's post-MVP list stays out, most notably: team members, access PINs, content translation as a feature, every integration (Airbnb/PMS/WhatsApp), upsells, and any rename or Hospello-account convergence.

### 2. The critical path
Phase 0 (product axis) → Phase 1 (brand/host + marketing shell, in front of signup) → Phase 2 (accounts + signup + builder — the longest pole, containing the first mailer) → Phase 3 (public guide + AI) → Phase 4 (billing) → Phase 5 (rollout). Marketing *content* polish (Phase 1 copy/design) and the Stripe dashboard/DNS/SMTP external setup can proceed in parallel with Phases 2–3; everything else is sequential.

### 3. Total estimated implementation effort
**31–45 engineer-days** (S=2–3, M=4–6, L=9–12, L=7–10, L=6–9, M=3–5), plus external lead times that cost calendar not effort: DNS/TLS, SPF/DKIM warm-up, Stripe live-mode setup. Run with this repo's implement → independent review → fix → re-review loop, which the estimate already assumes.

### 4. First implementation task after approval
Commit this plan as `docs/plan/askello-plan.md` (the repo's convention: the plan is the contract, in-tree), then **Phase 0, task 1**: the `AddProductToHotels` migration + `Hotel.product` enum + `Brand` registry + the `/h` product filter + `Platform::HotelsController#plan` askello refusal — with the break-the-code tests for both boundaries, full suite green, pushed to `claude/askello-product-planning-si0r34`.
