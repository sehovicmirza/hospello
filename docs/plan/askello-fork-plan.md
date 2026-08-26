# Askello fork plan — separate repo, separate app, separate database

> **Status: APPROVED PLAN — the chosen path. Execution happens in the separate `askello` repository,
> not here.** The owner reviewed the monolith plan ([askello-plan.md](askello-plan.md)) against a fork
> recommendation and chose the fork. This repo's only obligations from here are the mirror discipline
> (see HANDOVER.md) and staying untouched. If you are an agent working in *this* repo: do not build
> Askello features here.

## Context

The monolith plan (`docs/plan/askello-plan.md`, committed at `f49cf2c`) designed Askello as a second brand inside the Hospello Rails app. After reviewing it with another agent, the owner has chosen the **fork** direction instead: Askello becomes its own product in its own repository, its own Rails app, its own Render service, its own Postgres — created by cloning Hospello, deleting the hotel-only surface, and renaming the vocabulary. The owner asked for the fork plan: the deletion manifest, the rename map, the mirror list, and a revised phase breakdown, comparable side by side with the monolith plan.

This plan was built by re-measuring the actual repository (at `f49cf2c`) rather than trusting the numbers quoted in that discussion. The monolith plan's audit (its §1–3) and its net-new designs (auth, guide builder, AI generation, billing, analytics — its §5 Phases 2–4) remain the reference; this document covers what changes when the substrate is a fork instead of a shared app.

## The decision, verified

Measured with `git ls-files` + `wc -l`, deduplicated (no file counted twice):

| Bucket | Files | Lines | Verdict on the quoted claim |
|---|---|---|---|
| **Delete clean** — service requests/drafts/events, departments/categories, rooms + room limits, the entire WhatsApp subsystem, the translation overlay pipeline, plan gating, platform hotel-admin creation, demo seeds, `HotelDefaults`, their tests, fixtures and locales | 126 | 13,637 | The quoted "~99 files / ~10,700 lines" **undercounted** — it's bigger |
| **Transform, not delete** — the surviving staff namespace (conversations, kb_entries, settings, QR, analytics, users, dashboard) that becomes the host dashboard | 33 | 2,029 | The discussion called this "deleted"; it isn't — it's Askello's host UI, adapted |
| **Shared lineage** — AI core, tenancy tripwires, retention, rack_attack/CSP | 35 | ~6,300 | Of which the **actively mirrored core** (files where a fix in one repo almost certainly belongs in the other) is ~15 files / ~3,000 lines — the quoted "9 / 2,400" is the right order |
| Whole repo (`app test config db lib`) | — | 43,518 | The fork sheds ~31% of the codebase outright |

**What I confirm:** the delete-to-mirror ratio (4–5:1) holds and is better than claimed; the isolation argument (separate DB = isolation, not mitigation; an Askello vulnerability cannot become a Hospello incident) is valid; Hospello is feature-complete at slice 7, so the shared substrate is effectively frozen and the mirror tax is low; the renames are only affordable now, in a repo with zero production rows.

**What I correct:** (1) *"Renames for free" is wrong* — renaming the tenant root touches `acts_as_tenant` declarations, ten surviving FK columns, `Current`, fixtures, locale families, and every tripwire's grep patterns: mechanical, but 2–3 real days with breakage. (2) *Speed is roughly a wash to MVP* — my phase-by-phase estimate is 29–44 engineer-days vs the monolith's 31–45; the fork's true win is what you carry afterwards (a permanently smaller codebase, no "don't break Hospello" tax on any edit), not time-to-launch. (3) *The recurring tax the discussion missed is ops, not files* — a second Render service + DB + Sentry + heartbeat + CI + secrets + domains, and every future Rails/security bump done twice; that outweighs the 15 mirrored files. **The flip condition stands:** if the long-term intent is convergence (Hospello hotels getting self-serve guides, one billing system), the monolith plan is right and this one is wrong — only the owner knows.

---

## Fork mechanics

1. **New private GitHub repo `askello`** (owner creates it, or grants this session access via the repo picker — the current session is scoped to `sehovicmirza/hospello` only and cannot create repos).
2. **Keep full git history** (recommended): clone Hospello, point `origin` at the new repo, push. History is secret-clean — `config/master.key` was purged before Hospello's first push ever happened (recorded in HANDOVER). One caveat for the owner: the four *real Sarajevo hotels'* seed data files remain reachable in history even after F0 deletes them; the repo is private, so this is acceptable — if the owner wants zero trace, start instead from a single orphan import commit and lose blame/context.
3. **New Render Blueprint** in the same workspace: service `askello` (plan **starter**, not free — a self-serve funnel cannot ride an instance that sleeps), database `askello-db`, own `RAILS_MASTER_KEY` (generate fresh credentials — do not copy Hospello's), own `SENTRY_DSN`, own `HEARTBEAT_URL`, own `ANTHROPIC_API_KEY` (separate key = separate cost attribution), own R2 bucket.
4. **Hospello is untouched by construction.** The only changes to the hospello repo are the two small commits in "Hospello-side changes" below.

---

## Phase F0 — Fork + deletion pass (2–4 days)

**Objective:** a running, green, hotel-free skeleton. Order matters: callers before callees, tests die only with the code they cover, `bin/rails test` green at every commit boundary.

### Deletion discipline (the guardrails the deletion pass lives or dies by)
- **A failing test is never deleted to make the suite pass** — it is deleted only in the same commit as the code it covers, or it has found a caller you missed. This codebase's history (CLAUDE.md, 20+ instances) is exactly why.
- The **tripwires are never deleted, only updated**: `test/tenancy/*` (EXEMPT text, allowlist entries for removed files), `test/services/retention/policy_test.rb` (rules for dropped tables come out of `Retention::Policy` — the completeness test forces the update), `test/i18n/locale_files_test.rb` (`FAMILY_LOCALES` loses the `requests` family), injection corpus (loses the five request/room tool shapes, keeps everything else).
- One subsystem per commit, suite green between, in this order (dependencies point backwards):

### The manifest

| # | Subsystem (measured) | What goes | Gotchas — the callers to remove first |
|---|---|---|---|
| 0 | **Demo seeds** — 6 files, 1,677 lines. **First commit**: `db/seeds/demo*` | Real hotels' names and facts | `test/seeds/demo_seed_test.rb` dies with it; `db/seeds.rb:32` loses the `SEED_DEMO` hook (rebuilt in F4 for the sample property) |
| 1 | **WhatsApp** — 43 files, 4,887 lines: `app/{models,services,jobs}/**whatsapp**`, `Webhooks::WhatsappController`, staff channel/template screens, `config/initializers/whatsapp.rb`, `docs/whatsapp-onboarding.md`, fixtures, `phonelib` gem | The whole second channel | `Conversation#deliver_to_whatsapp` guard inside `broadcast_new_message`; `Message` delivery ladder (`claim_delivery!`, `apply_delivery_status!`, `DELIVERY_PROGRESS`); `GuestSession.for_whatsapp`/`renew_for_whatsapp!` (**but keep the roomless/consent-stamp pattern in mind — F4's anonymous entry is modeled on it**); `channel` enums on guest_sessions/conversations; render.yaml + `.env.example` WHATSAPP_* secrets; the without_tenant allowlist entry for `WhatsappChannel.route`. **Keep `WebhookEvent`** (model, table, dedupe pattern) — it is the Stripe substrate; its provider enum resets to `{stripe: 0}` in F5 |
| 2 | **Service requests, drafts, events** — 25 files, 3,044 lines + `config/locales/requests.{bs,en,de,ar}.yml` | The confirm-before-create machine, the board, the receipts | `Ai::Tools` propose/confirm handlers + `REQUEST_TOOLS`; `<pending_draft>` + `<request_categories>` blocks in `PromptBuilder`; guest `_draft_card` partial + its always-rendered Turbo target in `guest/chats/show`; `HotelRequestsChannel`; `ServiceRequests::ExpireDraftsJob` + its `recurring.yml` entry; `Analytics::HotelReport`'s request questions (report shrinks to usage/AI/gaps) |
| 3 | **Departments + request categories** — 17 files, 1,200 lines + `HotelDefaults` (71) | Hotel furniture | `GuestChatHelper` quick-action chips rebuild from guide sections instead (F4); `Platform::HotelsController#create` drops the `HotelDefaults.apply!` call |
| 4 | **Rooms + limits** — 10 files, 1,024 lines (`Room`, staff rooms screens, bulk paste, `room_limit` suite) | Room identity entirely | Guest entry form's room field + `find_active_room` (entry rebuilt in F4 as anonymous); `set_guest_room` tool + `<room_unknown>` prompt block; `GuestSession`/`Conversation` `room` associations + `room_must_belong_to_the_same_hotel`; `PLAN_ROOM_LIMITS` |
| 5 | **Translation overlay** — 10 files, 814 lines: `Ai::{Translator,Translation,DigitGuard}`, the three translate jobs, `shared/_translated_body`, `translation_toggle_controller.js`, watchdog recurring entry | Guest↔staff overlay pipeline | `Message` translation columns/methods (`claim_translation!`, `apply_translation!`, `translation_target_locale`, `readable_in`); `Conversation#request_staff_translations!`/`broadcast_translation`; `TRANSLATION_MODEL` from `config/initializers/ai.rb` + env docs. *Deliberate loss*: paid guide translations later mean porting the seam back from Hospello — recorded in the new HANDOVER |
| 6 | **Plan gating** — 8 files, 631 lines + the plan sections of `hotel.rb` (enum, `PLAN_FEATURES`, `plan_allows?`) | Hospello's capability tiers | `PromptBuilder.static_rules_for` collapses to the ESSENTIALS branch (becomes GUIDE_RULES in F4); `PlanGated` + `plan_upgrade` view; `QrCardHelper` keeps only `QUESTIONS_LINES`; `Platform::HotelsController#plan` route/action; Askello's commercial plans arrive on `Account` in F5, exactly as monolith-plan §5 Phase 4 designed |
| 7 | **Platform hotel-admin creation** — 3 files, 233 lines | Assisted onboarding | Self-serve signup replaces it (F3); platform admin keeps suspend/erasure/analytics |
| 8 | **DB cleanup migration** (one migration; the fork's DB is fresh, so drops are free) | Tables: `rooms, departments, request_categories, service_requests, service_request_drafts, request_events, whatsapp_channels, whatsapp_templates`. Columns: `hotels.{plan, room_limit, overdue_after_minutes, escalation_email, staff_locale}`, `guest_sessions.{room_id, phone_e164, channel}`, `conversations.{room_id, channel, escalation_reason?→keep}`, `messages.{translated_body, translated_locale, translation_status, delivery_status, delivered_at, external_id}` | **Rule: grep every column's readers before dropping it — every reader must already be in the deleted set.** Keep `hotels.checkout_time` (rentals have checkout), `contact_phone`/`contact_notes` (host contact + AI notes), `settings` jsonb |

**F0 exit gate:** full suite green; `bin/rails db:prepare` from an empty database succeeds; app boots and `/h/<slug>` still serves a (room-less) landing; `git grep -lE 'whatsapp|service_request|department|request_categor'` returns nothing outside `docs/`.

## Phase F1 — Rename + identity pass (2–3 days)

**Objective:** the code reads as Askello. Delete first (F0), then rename — there is far less to rename. One rename per commit, suite green between. **Not free**: this is where interlocked tests break; budget for it.

| Old | New | Mechanics and gotchas |
|---|---|---|
| `Hotel` / `hotels` / `hotel_id` | `Property` / `properties` / `property_id` | Table-rename migration + the **ten surviving FK columns** (users, guest_sessions, conversations, messages, kb_entries, unanswered_questions, ai_runs, ai_usage_days, audit_logs, webhook_events); `TenantScoped` → `acts_as_tenant :property`; `Current.hotel` → `Current.property`; every `hotel_*` helper/policy/channel name; lograge's `hotel_id` tag; fixtures; the tenancy tripwires' EXEMPT prose and grep patterns |
| `KbEntry` | `GuideSection` (recommended, same pass) | Table + class + fixtures; **keep the `[kb: N]` citation marker and `<kb_entry>` prompt tag names** to minimize prompt churn and keep the mirror diff against Hospello's `prompt_builder.rb` readable — rename only the Ruby/table layer |
| Roles `{staff, hotel_admin, platform_admin}` | `{host: 0, platform_admin: 1}` | Fresh DB, no rows — renumber freely; `hotel_membership_matches_role` → host requires `account_id` (F3 adds accounts; until then host requires `property` via a temporary rule), platform_admin requires none |
| `/h/:hotel_slug` | `/g/:property_slug` | `HotelQrCode` → `PropertyQrCode` with `#path = "/g/#{slug}"` — the pinned-path tests move with it |
| Cookie `:hospello_guest` | `:askello_guest` | Entries controller, guest base, **`ApplicationCable::Connection`** (the hardcoded read), `test_helper`'s `sign_in_guest` |
| `module Hospello` | `module Askello` | `config/application.rb`; `database.yml` names `askello_*`; `render.yaml` service/db names; QR download filenames; `AppHost::MISSING_MESSAGE` |
| Locale families `guest.*` / `staff.{bs,en}` / `degraded.*` | `guide.*` / `host.en` / `degraded.*` reworded | `FAMILY_LOCALES` rewritten; host UI ships **en-only** (`STAFF_LOCALES` → `HOST_LOCALES = %w[en]`, `User#locale` validation follows); guide chrome keeps bs/en/de/ar unless the owner says en-only; `degraded.reception_will_reply` → `degraded.host_will_reply` in all guide locales at once |
| Staff namespace (33 files, 2,029 lines) | `host/` namespace | **Transform, not rewrite**: conversations → questions (keep transcript, reply composer and resolve — "the host will reply" must be true — drop internal notes, identity-verify, translation chips, pause-AI stays), kb_entries → guide sections, hotel_settings → property settings, QR screen, analytics (shrunk report), preferences; `users` screens die (single-user accounts until post-MVP) |
| Docs + agent contract | Rewritten | New-repo `CLAUDE.md` (same working rules, Askello product description), fresh `HANDOVER.md` (carrying the mirror note below + the "translation seam deleted, port from Hospello to restore" note), `README`, this file as `docs/plan/plan.md`; Hospello's slice docs deleted (they are that repo's history) |
| `allow_browser versions: :modern` | Moved to the authenticated base only | Fork-only simplification the monolith couldn't have: marketing + public guide must serve old phones (a guest reading a Wi-Fi code, a host on the funnel), the host dashboard may require modern. No `ActionController::Base` inheritance workaround needed |

**F1 exit gate:** `git grep -in hospello` → zero; `git grep -inwE 'hotel|hotels'` → zero outside `docs/plan/plan.md`'s history notes; full suite green; boot + `/g/<slug>` serves.

## Phases F2–F6 — build Askello (transfers from the monolith plan)

These phases are the monolith plan's Phases 1–5 **minus all brand-resolution machinery** (no `Brand` registry, no `AskelloHost` constraint, no `Current.brand`, no product enum or filters, no dual cookies, no per-product prompt branches or degraded keys, no byte-identical-Hospello pin tests, no both-brand QA matrix). Everything net-new transfers **verbatim by design** — read `docs/plan/askello-plan.md` §4–§5 in the hospello repo for the full detail of each:

- **F2 — Marketing site (3–5 days).** Root route *becomes* the landing (no constraint needed); pricing, sample guide, FAQ, legal ("PILOT DRAFT" marker, test-protected); UTM first-touch cookie; SEO meta. `robots.txt` rewritten for Askello (marketing indexable; `/g/` handled by header, below).
- **F3 — Accounts, signup, guide builder (8–11 days).** `accounts` table (plan, Stripe fields, `acquisition` jsonb) + `users.account_id`; registrations (one transaction: Account + User(host) + Property with **random-suffix slug**), gated by `ASKELLO_SIGNUPS_ENABLED`; password reset via `generates_token_for` (no table); first mailer + `SMTP_*` env (Resend); guide builder + `GuideGeneration` service (single forced tool, drafts only, category whitelist, ≤2000-char split, `AiRun kind: generation`) + `GenerateGuideJob`; photos (`has_many_attached`, existing validation pattern); guided checklist = the guide category list as empty-state prompts.
- **F4 — Public guide + Q&A + QR + events (5–8 days).** `/g/:slug` published-only (identical 404 unknown/unpublished; owner preview of drafts; `X-Robots-Tag: noindex` + meta; property branding via the untouched `BrandingHelper`); **GUIDE_RULES** replaces the F0-surviving ruleset (single ruleset — no branch); anonymous guest entry (auto-name, consent stamped at first question — the WhatsApp pattern, now native); entitlement gate **before** enqueue (Free never reaches the degrade path; budget 0 as defense in depth); `product_events` + `Track` (tenancy EXEMPT + retention rule — the tripwires still enforce this in the fork); unanswered questions → "answer & add to guide"; QR screen + print sheet; Rack::Attack throttles (guide questions, signup); rebuilt sample-property seed behind `SEED_DEMO`.
- **F5 — Billing (6–9 days). Identical to monolith Phase 4.** `stripe` gem; `PlanCatalog` + `Entitlements`; Checkout/Portal; `Webhooks::StripeController` written against Hospello's `webhooks/whatsapp_controller.rb` as the template (raw-body signature → `webhook_events` `ON CONFLICT DO NOTHING` → job on `:critical` → 200); processing job refetches state from Stripe; downgrade unpublishes, never deletes; account deletion (confirm-by-naming, cascade, audit).
- **F6 — Rollout (3–4 days).** Render Blueprint live (starter, `preDeployCommand: db:migrate` from day one — no free-tier build-script window); domain + SPF/DKIM; `config.hosts` (single brand — trivial); Sentry; smoke tests; limited beta. No dual-brand matrix — the manual QA matrix is the monolith plan's minus every Hospello row.

**Total: 29–44 engineer-days** (F0 2–4 · F1 2–3 · F2 3–5 · F3 8–11 · F4 5–8 · F5 6–9 · F6 3–4) vs the monolith's 31–45 — a wash to MVP; the payoff is the permanent one.

## The mirror list, and the discipline

Files whose fix in one repo almost certainly belongs in the other (~15 files, ~3,000 lines): `app/services/ai/{client,result,prompt,prompt_builder,concierge,outcome,tools,circuit_breaker}.rb`, `app/jobs/ai/generate_reply_job.rb`, `test/support/fake_claude.rb`, `test/services/ai/injection_corpus_test.rb`, `config/initializers/{rack_attack,content_security_policy}.rb`, `app/services/retention/policy.rb` and the `test/tenancy/*` patterns. Note `prompt_builder.rb` and `tools.rb` **diverge on day one** (GUIDE_RULES, deleted tools) — the mirror discipline for those is porting *classes of fix* (a new injection defense, an SDK change in `Ai::Client`, a sealing improvement), not keeping bytes identical.

Add this note, verbatim, near the top of **both** repos' `HANDOVER.md`:

> **Mirror discipline:** this codebase shares its AI-safety substrate with `sehovicmirza/hospello` ⇄ `sehovicmirza/askello` (Ai::Client and the concierge loop, prompt sealing and citation validation, the injection corpus, circuit breaker, rack_attack/CSP patterns, tenancy-tripwire patterns, retention shape). **A security or correctness fix in any of these files must be evaluated for the sibling repo in the same session, and the sibling's HANDOVER updated with either the ported fix or the reason it doesn't apply.**

## Hospello-side changes (the only edits to this repo)

One small commit, pushed to `main` per the owner's standing instruction: (1) the mirror note above into `HANDOVER.md`, plus a line recording the fork decision and pointing at the `askello` repo; (2) `docs/plan/askello-plan.md` status header updated — "the owner chose the fork path (see `docs/plan/askello-fork-plan.md`); this document remains the audit of record and the reference design for the net-new subsystems"; (3) this document committed as `docs/plan/askello-fork-plan.md` so local agents can read both plans side by side.

## Risks and guardrails

1. **The deletion pass is the failure mode** — breaking tests you don't understand and deleting them is exactly what CLAUDE.md was written against. The guardrails above (same-commit rule, tripwires update-only, one subsystem per green commit) are the plan's load-bearing part.
2. **The rename pass breaks the tripwires' own grep patterns** — they grep for `hotel_id` and platform paths; update the patterns *with* the rename commit, and prove each tripwire still fires by breaking one thing it guards afterwards.
3. **Ops duplication is the permanent tax** — two services, two DBs, two Sentry/heartbeat/CI pipelines, every Rails/security bump twice. Accepted knowingly; it is the price of isolation.
4. **The convergence flip** — if Hospello hotels are ever meant to get self-serve guides on shared billing, this plan fights the destination. Confirmed direction before F0 starts, or stop at F0 and revert to the monolith plan (nothing is lost — the fork repo is simply abandoned; Hospello was never touched).
5. **Anthropic spend now splits across two keys** — set both budgets deliberately; the per-property daily budget machinery survives the fork untouched.

## Open questions (defaults chosen; none block F0)

1. **Repo name** — default `askello`, private, same owner.
2. **Keep git history?** — default **yes** (secret-clean, context-rich); the owner should explicitly accept that the four real hotels' seed files remain in history, or choose the orphan-commit start.
3. **Rename `KbEntry` → `GuideSection` now?** — default yes (F1), keeping prompt tag + citation marker names.
4. **Delete the translation seam?** — default yes; restoring paid guide translations later = porting `Ai::Translator`/`DigitGuard` back from Hospello (recorded in HANDOVER).
5. **Guide chrome languages** — default keep bs/en/de/ar (files exist; AI answers any language regardless); host UI en-only.
6. **Same Render workspace?** — default yes, separate services; separate workspace only if billing separation of the *infrastructure* matters to the owner.

## Verification

- **Every F0/F1 commit:** `bin/rails test` green (system suite too when views/JS change); rubocop + brakeman clean; the grep gates named at each phase exit.
- **F0 exit:** fresh-database `bin/rails db:prepare` + boot + a served `/h` page; deletion greps return zero.
- **F1 exit:** `git grep -in hospello` zero; suite green; `/g/<slug>` serves; each tripwire proven still able to fire (break one guarded thing, watch red, restore).
- **F2–F6:** the acceptance criteria in `docs/plan/askello-plan.md` §5 apply per phase, minus every "Hospello byte-identical" check (structurally void in a fork).
- **Cross-repo:** after the Hospello-side commit, `HANDOVER.md` in both repos carries the mirror note.

## First task after approval

Commit this document to the hospello repo as `docs/plan/askello-fork-plan.md` together with the Hospello-side HANDOVER/status edits (push to `main`, per standing instruction) — then, once the owner has created the `askello` repo and granted access: **F0 commit 1, deleting the demo seeds** (the files carrying real hotels' names leave the tip immediately), and proceed down the manifest one green commit at a time.
