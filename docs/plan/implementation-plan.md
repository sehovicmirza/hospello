# Hospello MVP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan slice-by-slice. Each slice gets its own detailed task breakdown (bite-sized TDD steps) at execution time; this document locks scope, architecture, data model, and ordering.

**Goal:** Build a production-quality, multi-tenant Rails MVP of Hospello — an AI digital concierge that lets hotel guests chat with their hotel via a branded QR web chat (and later the hotel's own branded WhatsApp number), with grounded AI answers, confirmed service requests, translation, and a live reception dashboard — deployable to Render for real Sarajevo hotel pilots.

**Architecture:** Single Rails 8.0 monolith (Hotwire/Turbo server-rendered), one Postgres database doing quadruple duty (app data + Solid Queue + Solid Cable + Solid Cache — no Redis), row-level tenancy that fails closed, Anthropic API for the concierge and translation, WhatsApp behind a provider port speaking the Meta Cloud API payload shape. No microservices, no vector DB, no extra infrastructure.

**Tech Stack:** Ruby 3.4.3 · Rails 8.0.x · PostgreSQL · Hotwire (Turbo 8 + Stimulus) via importmap · tailwindcss-rails · Rails 8 auth generator · Pundit · acts_as_tenant · Solid Queue/Cable/Cache · official `anthropic` gem · `rqrcode` · `rack-attack` + Rails `rate_limit` · `phonelib` · Active Storage → Cloudflare R2 · Minitest + fixtures + Capybara + WebMock · sentry-ruby · lograge · mission_control-jobs · Render (1 web service + managed Postgres)

## Global constraints (from the spec — every slice inherits these)

- Rails monolith; deployable to Render via documented steps. No secrets committed; no hidden manual steps to deploy.
- **One reusable QR code per hotel** — not per-room, not shared across hotels.
- Guest identity is **always unverified** (self-entered room number); displayed as such to staff; never used to reveal sensitive data.
- AI answers **only** from the hotel's *published* KB + hotel settings; never invents prices/hours/availability; never claims anything is approved until staff acts. Requests are *pending* until a human accepts.
- Exactly **one** service request per confirmed ask — no duplicates, confirmed by the guest before creation.
- Originals are immutable; translations are overlays; original-vs-translated is visually obvious; numbers/times/names never silently altered.
- Guest languages v1: **bs, en, de, ar (RTL correct)**. Staff UI: **bs + en** via Rails i18n.
- Graceful degradation: AI or translation down → guest can still message reception. No dead ends. Chat is not an emergency channel (say so).
- Hotel is the dominant brand; "Powered by Hospello" is discreet and **platform-admin-toggleable per hotel** (`hotels.powered_by_visible`).
- Tenant isolation is absolute and covered by automated tests.
- Phone optional; minimal PII; never request payment cards / ID documents in chat; retention + deletion implemented; legal copy marked "review before production."

## Context

The repo (`~/projects/hospello`) is empty — a greenfield build (verified: only `.git`, no commits). The user supplied a complete product spec. Fixed constraints: Ruby on Rails, deployable to Render; everything else was ours to decide with a mandate for "the simplest reliable approach that can support real hotel pilots."

**How this plan was produced:** three independently-biased architecture proposals (simplicity-first, operations-first, product/AI-quality-first) plus two live-research briefs (WhatsApp Business Platform onboarding as of 2026-08; Render's current Rails 8 deployment surface, plans, and pricing) were adversarially judged on spec compliance and technical failure modes. Verdict: base on the operations proposal (only one free of the concurrent-double-reply race; fail-closed tenancy; real ops story), graft in the product proposal's guest-facing layer (RTL, branding, confirm-cards, grounding citations), take the simplicity proposal's leaner phasing, and fix gaps all three missed (per-hotel QR — not per-room; powered-by toggle; configurable categories/departments; WhatsApp provider economics). The user's existing `homeflow/concierge` project (Rails ~8.0.5, solid_queue, Minitest + fixtures) sets team conventions this plan follows.

## Product understanding

Each hotel gets one reusable QR code. Scanning opens a fast, mobile-first, hotel-branded page. The guest enters full name + room number (validated against the hotel's active room list), picks a language (auto-preselected from `Accept-Language`), optionally a phone, accepts a concise privacy notice — then chats. Quick-action chips (towels, cleaning, report a problem, wake-up call, breakfast info, contact reception) prefill the composer; free typing always works. An AI concierge answers only from that hotel's published knowledge base, gathers details for service requests, shows a summary card, gets confirmation, and creates exactly one request. It escalates honestly when it can't answer and logs the gap for the hotel. Reception sees a live queue and conversation inbox in their language (original + translation both visible), replies (auto-translated to the guest), assigns, tracks, completes — and can pause the AI to take over. WhatsApp is an optional second channel per hotel on the hotel's own branded number, feeding the same dashboard.

**Primary journeys:** (1) Guest: scan → identify → ask/request → confirm → live status updates in own language → session persists in browser. (2) Receptionist: live queue + inbox → open item → original+translation → accept/assign/note/complete → guest auto-notified → take over / hand back to AI. (3) Hotel admin: branding/rooms/departments/categories/staff/KB (draft→published) → readiness checklist → QR download + print sheet → analytics + unanswered questions → WhatsApp connect. (4) Platform admin: create/suspend hotels, first hotel-admin, per-hotel usage, audited support access.

## Assumptions

1. **AI provider:** Anthropic API. Concierge on `claude-opus-5` (`output_config: {effort: "low"}`, `max_tokens: 1024`, prompt caching on the KB block); translation on `claude-haiku-4-5`. Both ENV-configurable (`AI_MODEL`, `TRANSLATION_MODEL`). An `ANTHROPIC_API_KEY` will be provided.
2. **Pilot scale:** 1–5 hotels, tens of rooms each, low hundreds of conversations/day — justifies single-service deployment, DB-backed queues, and whole-KB prompt inlining (a hotel KB is tens of entries ≈ 2–5K tokens; retrieval infra would add failure modes for zero benefit, and prompt caching makes repeat turns nearly free).
3. **WhatsApp (research-verified 2026-08-06):** built against the **Meta Cloud API payload shape** behind a provider port. Development starts day one on Meta's **free test number** (no verification needed, 5 test recipients). For production hotel numbers the recommended BSP is **360dialog** (zero per-message markup, ~€49/mo/number, hosted Embedded Signup so each hotel gets its own WABA + number + display name, documented **Coexistence** so a hotel's existing WhatsApp Business app number keeps working) — Twilio (~$0.005/msg markup, different payload shape) is the runner-up; Meta-direct Tech Provider is the long-term path once Hospello passes Meta App Review. Unverified hotels can send 250 business-initiated conversations/day — ample for a pilot. This is a business decision flagged in *Blocking questions*; it does not block development.
4. **Team conventions** (from `homeflow/concierge`): Rails 8.0.x, Minitest + fixtures, Solid stack. Followed here.
5. **Assisted onboarding** by the platform admin; no self-service signup, no billing.
6. **Legal copy** ships as clearly-marked pilot drafts.
7. Local dev environment verified: Ruby 3.4.3, Rails 8.0.5.1, Postgres on 5432.

## Explicitly out of scope (per spec)

Native apps; PMS/booking/smart-lock/POS/payment integrations; online payments/billing; guaranteed real-time availability; auto-approval of anything; voice/call center; marketing/loyalty/review automation; staff scheduling/inventory; **per-room QR codes**; self-service signup. Clean seams kept for later: channel provider port, `Ai::Client` seam, categories/departments as data.

---

## Architecture decisions (with justifications)

| Decision | Choice | Why |
|---|---|---|
| Rails / Ruby | 8.0.x / 3.4.3 | Team convention (concierge app); Solid stack + auth generator built in |
| Frontend | Hotwire (Turbo 8 + Stimulus), importmap, Propshaft, tailwindcss-rails | No Node build chain; morphing page refresh doubles as realtime recovery; Tailwind standalone CLI |
| Auth | Rails 8 authentication generator (`has_secure_password`, DB `Session` rows) | Spec needs email+password staff login only; no Devise weight; full session-invalidation control |
| Authorization | Pundit | Small, explicit, per-record policies; second line of tenant defense (`record.hotel_id == user.hotel_id`) |
| Tenancy | `acts_as_tenant` with `require_tenant = true` | **Fail-closed**: unscoped queries raise instead of leaking; DB backstop via NOT-NULL FKs |
| Realtime | Turbo Streams over Action Cable + solid_cable (Postgres) | No Redis; broadcasts are enhancement, DB is truth; resync + polling fallback (below) |
| Jobs | Solid Queue, in-Puma (`SOLID_QUEUE_IN_PUMA=true`), 4 queues | Zero extra Render services at pilot; recurring via `config/recurring.yml`; mission_control-jobs for inspection |
| AI | Official `anthropic` gem behind one seam (`Ai::Client`) | One dependency; typed errors; structured outputs + tool use; testable via injected fake |
| WhatsApp | Provider port; first impl speaks Meta Cloud API shape | Works against Meta's free test number today and 360dialog tomorrow; BSP swap = adapter, not rewrite |
| QR | `rqrcode` SVG, generated on the fly | One QR per hotel encoding `https://APP_HOST/h/:slug`; printable sheet with instructions; nothing stored |
| Rate limiting | rack-attack (IP/session, middleware) + Rails `rate_limit` + per-hotel daily AI token budget | Three layers: cheap-reject abuse, throttle bursts, cap spend |
| File storage | Active Storage → Cloudflare R2 (S3-compatible, 10GB free, zero egress) | A Render disk would cost $0.25/mo but kills zero-downtime deploys and blocks multi-instance forever |
| i18n | rails-i18n + our YAML for staff UI (bs, en) and guest chrome (bs, en, de, ar); **pre-translated degraded-mode strings** | Degradation must never depend on the translation API |
| Testing | Minitest + fixtures, Capybara headless Chrome, WebMock `disable_net_connect!`, hand-rolled `FakeClaude` | Team convention; no VCR (cassettes rot and hide prompt drift); one `LIVE_AI=1`-gated smoke test |
| Ops | sentry-ruby, lograge, healthchecks.io dead-man heartbeat (pinged *from a recurring job*, so a dead queue pages), escalation nag emails via Resend SMTP | The pilot runs unattended; silent failure is the enemy |
| Email | Action Mailer via Resend SMTP free tier | Escalation nags + staff invites only |

Explicitly rejected: Devise, RSpec/FactoryBot, Sidekiq/Redis, vector DB/embeddings, per-hotel Twilio subaccounts, request-category SLA timers, separate services.

## Core concepts & data model

All tenant tables carry `hotel_id` (NOT NULL, FK, leading column of composite indexes). Integer-backed Rails enums. Framework tables (Solid Queue/Cable/Cache, Active Storage) share the same Postgres.

- **Hotel** — tenant root. `name`, `slug` (unique; in the QR URL), `timezone`, `staff_locale` (default "en"), branding: `primary_color`, `secondary_color`, `concierge_name`, `welcome_message`, `contact_phone`, `contact_notes` (reception/emergency instructions), logo + optional welcome image (Active Storage), `powered_by_visible` (bool, default true, platform-admin-only), `status` enum {active, suspended}, `checkout_time`, `escalation_email`, `ai_enabled` (bool), `ai_daily_token_budget` (int, default 500_000), `overdue_after_minutes` (default 120), `settings` jsonb.
- **User** — staff + platform. `hotel_id` (nullable **only** for platform_admin — validated), `email_address`, `password_digest`, `name`, `role` enum {staff, hotel_admin, platform_admin}, `locale` (bs/en), `active`. **Session** per Rails 8 generator.
- **Room** — `number` (unique per hotel), `active`. Used only to validate guest-entered room numbers (no per-room tokens).
- **Department** — `name`, `active`. Seeded per hotel (Reception, Housekeeping, Maintenance, F&B) — editable.
- **RequestCategory** — `name`, `key`, `department_id`, `icon`, `active`, `position`. Seeded defaults (towels/bedding, cleaning, maintenance, wake-up call, breakfast/restaurant reservation, spa, luggage/taxi, other) — hotels edit freely; the AI tool's category enum is generated per hotel from this list. No SLA machinery.
- **GuestSession** — `room_id` (nullable for WhatsApp until gathered), `channel` enum {web, whatsapp}, `token_digest` (SHA-256 of the web cookie token), `phone_e164` (nullable; partial unique `[hotel_id, phone_e164] WHERE channel=whatsapp`), `guest_name`, `locale`, `identity_status` enum {unverified, staff_verified} (default unverified — **always**, per spec), `privacy_accepted_at`, `status` enum {active, blocked}, `last_seen_at`, `expires_at`.
- **Conversation** — `guest_session_id`, `room_id`, `channel` (denormalized), `status` enum {active, escalated, resolved, expired}, `ai_mode` enum {auto, paused}, `escalation_reason` enum {guest_requested, ai_uncertain, ai_unavailable, budget_exhausted, staff_manual}, `guest_locale`, `last_guest_message_at`, `last_message_at`, `staff_unread_count` (server-computed). **Partial unique index `[guest_session_id] WHERE status IN (active, escalated)`** — one live conversation per guest; concurrent creates race-safe (`rescue RecordNotUnique` → re-find).
- **Message** — `sender_role` enum {guest, assistant, staff, system}, `sender_user_id`, `body` (original, immutable), `body_locale`, `translated_body`, `translated_locale`, `translation_status` enum {not_needed, pending, translated, failed}, `client_message_id` (UUID from web composer; unique per conversation — web dedupe), `external_id` (provider message id; partial unique — WhatsApp dedupe), `delivery_status` enum {local, queued, sent, delivered, read, failed} + `delivered_at` (the **single-writer delivery claim**: `UPDATE ... WHERE delivered_at IS NULL` closes the translate-vs-timeout double-send race), `metadata` jsonb.
- **KbEntry** — `category` enum {facilities, dining, rooms, policies, local_area, transport, other}, `title`, `content` (plain text ≤2000 chars), `published` (bool — drafts never reach the prompt), `position`.
- **ServiceRequestDraft** — the confirm-before-create state machine. `conversation_id`, `request_category_id`, `details` jsonb (quantity, time, people, description…), `status` enum {gathering, awaiting_confirmation, confirmed, discarded, expired}, `expires_at` (30 min). **Partial unique index `[conversation_id] WHERE status IN (gathering, awaiting_confirmation)`** — one live draft. Confirmation creates the ServiceRequest inside one transaction with the draft's state change.
- **ServiceRequest** — `conversation_id`, `guest_session_id`, `room_id`, `request_category_id`, `department_id` (denormalized from category, reassignable), `summary` (staff-locale canonical), `details` jsonb, `details_original` + `original_locale` (guest's wording), `requested_for_at`, `status` enum {new, accepted, in_progress, completed, declined, cancelled}, `priority` enum {normal, high}, `assigned_to_id`, `source` enum {ai, staff}, `channel`, `dedupe_key` (SHA-256 of conversation+category+normalized details+time; **unique** — tool-retry backstop beneath the draft machine), `acknowledged_by_id/at`, `completed_at`.
- **RequestEvent** — visible history + internal notes in one table: `service_request_id`, `user_id`, `kind` enum {status_change, assignment, note}, `from_status`, `to_status`, `note` (internal; never guest-visible), timestamps. Guest-visible status updates are generated from status_change events, translated to the guest's language.
- **UnansweredQuestion** — `conversation_id`, `question` (staff-locale), `question_original`, `locale`, `normalized_hash` (unique per hotel — repeats bump `asked_count`), `asked_count`, `status` enum {new, answered, dismissed}, `kb_entry_id` (set by one-click "Answer & add to KB").
- **WhatsappChannel** — has_one per hotel. `phone_number_e164` (globally unique — routing key), `phone_number_id` (Meta routing id), `waba_id`, `provider` enum {meta_cloud, three_sixty_dialog, twilio}, `status` enum {pending, active, disabled}, `display_name_status`, `verified_at`, `last_inbound_at`, `last_error`.
- **WebhookEvent** — **not tenant-scoped** (exists pre-routing). `provider`, `external_id` (**unique `[provider, external_id]`** — idempotency anchor; inserted `ON CONFLICT DO NOTHING`), `payload` jsonb, `hotel_id` (resolved during processing), `status` enum {received, processed, ignored, failed}.
- **AiRun** — ops telemetry, purged at 30d: `kind` enum {reply, translation}, `model`, tokens (input/output/cache_read), `latency_ms`, `status` enum {success, timeout, api_error, refusal, budget_blocked, circuit_open}, `cited_kb_entry_ids` (int[], grounding audit).
- **AiUsageDay** — `[hotel_id, date]` unique; atomic upsert increments; budget checks read this.
- **AuditLog** — `actor_user_id`, `hotel_id` (nullable), `action`, `target_type/id`, `metadata` jsonb. Written for: platform-admin tenant access, hotel suspend/activate, staff create/deactivate, KB publish/unpublish, WhatsApp config changes, request status changes, guest-session block/verify, retention deletes.

## Key mechanism designs

### Tenancy (fail closed at four levels)
`acts_as_tenant(:hotel)` on every tenant model; `require_tenant = true` so unscoped queries **raise**. Namespaces set the tenant: `/h/:slug` + `/guest/*` from the guest cookie's hotel; `/staff/*` from `Current.user.hotel` (platform admins refused); `/platform/*` has no ambient tenant — cross-tenant reads only in audited `without_tenant` blocks (CI grep-test asserts `without_tenant` appears **nowhere in `app/` outside `app/controllers/platform/`**), and drilling into one hotel wraps in `with_tenant` + AuditLog line. Cable: signed stream names generated server-side from records; connection authenticates staff or guest cookie; channel re-verifies hotel match. Jobs: `ApplicationJob` around_perform sets tenant from GlobalID args or requires a `TenantFree` marker; cross-hotel recurring jobs iterate `Hotel.find_each` re-entering `with_tenant`. Verification: reflection test (every model with `hotel_id` declares acts_as_tenant), request tests hitting every staff route as hotel-A with hotel-B IDs asserting 404, forged-stream Cable tests, job-level tests.

### Guest identity (per-hotel QR, honest unverified state)
The hotel's QR encodes `https://APP_HOST/h/:hotel_slug` (public by design — it's printed everywhere). The branded landing shows logo/colors/welcome/contact + emergency note ("for emergencies call reception / 112") + a "Chat on WhatsApp" button when connected. The entry form: full name (required), room number (must match an active `Room` — friendly error otherwise), language (bs/en/de/ar, preselected from `Accept-Language`), phone (optional), privacy-notice checkbox. Submit creates GuestSession (**always `unverified`**) + signed httponly SameSite=Lax cookie (32-byte token, SHA-256 digest stored), 7-day rolling expiry (capped 21d). Returning with the cookie skips straight to the chat with history. Cookie lost → re-enter details (the recovery story; printed on the card). Staff UI renders "Room 204 · UNVERIFIED" hollow badges everywhere; one-click "Verified" (staff checked their PMS/paper) → solid badge + AuditLog. Prompt policy: privileged asks (billing, room changes, access) always escalate; requests from unverified sessions are created but badged. Abuse: rack-attack per-IP on entry + per-cookie on messages, 1000-char cap, staff can block a session.

### AI concierge (grounded, serialized, degradable)
Inbound guest message: (1) persist Message + touch conversation in one transaction (DB first, always); (2) `after_commit` broadcasts; (3) if `ai_mode == auto` && `hotel.ai_enabled` → `Ai::GenerateReplyJob` on the `ai` queue with `limits_concurrency to: 1, key: "ai-conv-#{conversation.id}"` — **replies serialized per conversation**; the job answers only the **latest** message batch (rapid-fire messages coalesce; no double replies; backlog collapses to one reply per conversation). Pre-flight guards in order: circuit breaker closed? daily budget < 90%? else degrade. Every outcome writes an AiRun.

Prompt (stable → volatile for caching): block 1 = static role + guardrails + tool policy (identical across hotels); block 2 = hotel card + **entire published KB** serialized deterministically as `<kb_entry id category>` inside `<hotel_knowledge>`, with `cache_control: {type: "ephemeral"}`; block 3 (after the cache breakpoint) = current local time in hotel TZ, room, unverified flag, guest name, live draft context. Messages = last 40 turns in original languages. Call: `AI_MODEL` (default `claude-opus-5`), `max_tokens: 1024`, `output_config: {effort: "low"}`, 25s timeout, 1 retry. Reply language: prompt rule "always reply in the guest's most recent language" (natively multilingual — no detection call on the hot path).

**Grounding rules:** hotel facts ONLY from `<hotel_knowledge>` + hotel card; cite entry ids (stored on AiRun.cited_kb_entry_ids for audit); no answer in the KB → MUST NOT guess → `log_unanswered_question` + honest "I'll pass this to our team" + offer handoff. Never state or imply approval of anything pending. Off-topic → polite redirect. Emergencies → call reception/emergency services.

**Tools (strict schemas; the only side-effect channel; max 2 round-trips then forced text):**
- `propose_service_request(category_key, details, requested_for?, clarifying_question?)` — creates/updates the conversation's live ServiceRequestDraft; missing required details keep it `gathering` (one clarifying question at a time); complete → `awaiting_confirmation` and the guest sees a **summary card** (Turbo frame: icon, details, time, room, Confirm / Change / Cancel) — and a plain-text "yes"/"da"/"ja"/"نعم" also works because the open draft is injected as `<pending_draft>` context and the model calls `confirm_service_request`.
- `confirm_service_request(draft_id)` — transactionally flips the draft and creates the ServiceRequest (category validated against the hotel's list, room from session never from the model, `dedupe_key` computed → retries are no-ops), broadcasts to the staff board, returns a receipt the model relays ("Your request was sent to reception — it's **pending** until they confirm").
- `escalate_to_staff(reason, summary)` — conversation → escalated, staff notification, nag timer starts.
- `log_unanswered_question(question, question_original)` — hash-upsert; repeat asks bump the count.

**Injection resistance:** guest text and KB content are data inside tags, declared as such in the static block; tools are the only actions and every argument is server-validated; the prompt is single-tenant by construction (cross-hotel leakage structurally impossible); output length capped; CI corpus of jailbreak strings asserts no tool side effect without server validation and correct prompt structure.

**Degradation:** `Ai::CircuitBreaker` in Solid Cache (opens after 4 consecutive timeouts/5xx in 3 min; half-open probe at 2 min). Open / final-failure / budget-blocked / `stop_reason: refusal` → post a `system` Message from **pre-translated YAML strings** ("Our team has been notified and will reply personally shortly"), auto-escalate with reason, dashboard banner "AI assistant paused — guests are being answered manually". Guests can keep messaging throughout; persistence and staff routing never depend on Anthropic.

### Translation (immutable originals, mechanical safety)
- **Guest → staff:** async `Translations::TranslateMessageJob` (Haiku, structured output `{translated_text, detected_source_lang}`) into `hotel.staff_locale`; result overlays onto the row; `conversation.guest_locale` updates from detection. Dashboard renders the translation full-weight with an "AR → EN" chip; tapping expands the original (RTL-rendered) underneath. Failure → original + "translation unavailable" chip + retry button; never delays display.
- **Staff → guest:** the Message persists immediately; **delivery deferred behind translation with a 15s budget** enforced by a watchdog job scheduled at enqueue (`Messaging::DeliveryTimeoutJob.set(wait: 15.seconds)`). Whichever finishes first — translation or timeout — claims delivery via the single-writer `UPDATE messages SET delivered_at=now() WHERE id=? AND delivered_at IS NULL`; the loser no-ops (no double send on WhatsApp). Timeout/failure path delivers the original prefixed by a pre-translated "Message from our team:" note. Same-locale skips the pipeline. Target locale = `guest_session.locale` (chosen at entry — no first-reply race on web).
- **AI messages:** never translated on the hot path (already in the guest's language); dashboard has lazy per-message "translate for me".
- **Digit guard (code, not trust):** normalize Eastern-Arabic numerals (٠-٩ → 0-9) then compare digit-run multisets between source and output; mismatch → one corrective retry naming the missing tokens → still failing → `translation_status: failed`, fall back to original. Unit-tested against a corpus of times/prices/room numbers.
- **Budget ordering:** concierge stops at 90% of the hotel's daily tokens; translation runs to 100% — staff↔guest communication is the degraded-mode lifeline.

### Realtime & jobs (broadcasts are enhancement, DB is truth)
All broadcasts `after_commit`. Guest chat: Stimulus `resilience` controller reloads the messages frame (`GET /guest/messages?after=<last_id>`) on cable reconnect and on `visibilitychange` (the pocket-phone case), and polls every 20s while the cable is down. Staff dashboard: Turbo 8 morphing refresh + 60s fallback poll; unread counts always computed server-side. Queues (in-Puma): `critical` (webhooks, WhatsApp delivery — never behind LLM calls), `ai` (2 threads — deliberate backpressure), `default` (emails, QR sheets), `low` (purges). Recurring: `CloseStaleJob` (idle > **72h** → expired; a returning guest reopens context by messaging again), `Escalations::NagJob` every 5 min (unclaimed >10 min → email + re-broadcast — the "staff tablet fell asleep" net), `Retention::PurgeJob` daily 04:00 hotel-local, `Ops::HeartbeatJob` every 5 min → healthchecks.io (queue-originated dead-man), `Ops::QueueHealthJob` every 10 min → Sentry on failed-execution/oldest-age breach. All jobs idempotent (unique indexes / dedupe keys); Solid Queue is at-least-once.

### WhatsApp (per-hotel branded number, provider port)
`Whatsapp::Provider` port: `send_text(channel, to, body)`, `send_template(channel, to, name, locale, components)` → provider_message_id; inbound normalized to one struct (hotel_id, wa_id, type, text, timestamp, provider_message_id); statuses normalized likewise. First implementation: **MetaCloudProvider** (works against Meta's free test number from day one; 360dialog shares the payload shape). Webhook `POST /webhooks/whatsapp`: verify `X-Hub-Signature-256` (HMAC-SHA256 of the **raw body**, constant-time compare; GET handshake for `hub.challenge`), insert WebhookEvent `ON CONFLICT DO NOTHING`, return 200 in <1s, enqueue `Whatsapp::ProcessInboundJob` on `critical`. **Signature-valid webhook requests are exempt from rack-attack throttles.** Routing: `metadata.phone_number_id` → WhatsappChannel → hotel (`with_tenant`); unknown → ignored + Sentry. Guest: find-or-create GuestSession by phone; the AI's first job on a roomless session is to ask name + room number conversationally; the answer is validated against `hotel.rooms.active` via a `set_guest_room(room_number, guest_name)` tool (invalid → re-ask; valid → bind room, still `unverified`). Downstream pipeline identical to web (translate, AI, requests, broadcasts). 24-hour window modeled explicitly: `send_text` raises `WindowClosed` when `now > last_guest_message_at + 24h`, forcing the template path; staff see "WhatsApp couldn't deliver — the guest must message first." **Welcome message:** one pre-approved *utility* template per hotel WABA ("Welcome to {hotel} — save this number to reach reception anytime"), sent only to opted-in numbers collected at check-in (opt-in checkbox naming WhatsApp explicitly); template registry tracks per-hotel approval status. Landing-page "Chat on WhatsApp" button links `wa.me/<number>` with a prefilled greeting (no tokens embedded — room binding happens in-conversation). Onboarding runbook (starts slice 1 — Meta review is the project's longest external lead time): display name = hotel's trading name; number strategy (Coexistence on the existing WhatsApp Business number = low-friction default; fresh number = plan B); Meta business verification deferred until >250 business-initiated conversations/day; docs clearly mark which steps are Meta's/BSP's timelines, not ours.

### Reception dashboard
Two lanes: **Requests board** (filter: status, category, department, room, assignee, date, channel; search: guest name, room, content; overdue flag when `new`/`accepted` older than `hotel.overdue_after_minutes`) and **Conversation inbox** (open/escalated/resolved tabs; strong unread badges; escalated jumps lanes with color + sound). Request detail: full conversation, original + translated, status buttons (accept → in progress → complete / decline with reason), assignment, internal notes (visually separated, never guest-visible), history timeline from RequestEvents. Conversation detail: chat with translation chips, "Pause AI / Return to AI" toggle (re-checked inside the reply-persist transaction so a mid-flight AI reply can't land after takeover), composer with "will be delivered in العربية" hint. Desktop/tablet primary, responsive to mobile. Staff UI locale per user (bs/en). Timestamps in hotel timezone.

### Hotel admin & onboarding
Sections: Profile & branding (colors via CSS custom properties driving the guest UI live-preview; logo/welcome image), Rooms (bulk paste "101-120, 201-220"), Departments & categories, Staff (invite by email), Knowledge base (draft/publish, positions, category tabs), QR & print (SVG/PNG download + printable A5 sheet with instructions in 4 languages), WhatsApp (status, runbook link), Analytics, Unanswered questions. **Readiness checklist** banner: branding set · ≥1 room · ≥1 staff · ≥5 published KB entries · categories confirmed · test conversation done · test request completed — each linking to the fix. "Preview as guest" opens the real guest flow in a sandbox conversation flagged `test: true` (excluded from analytics).

### Analytics (SQL over the tables, per-hotel, date-range selectable)
Conversations count (by channel, by day); requests by category/status/department/channel; median/p90 time-to-accept and time-to-complete; open + overdue now; guest language distribution; common questions (most-cited KB entries via `AiRun.cited_kb_entry_ids` — what guests actually ask about); top unanswered questions; AI containment (conversations resolved without escalation). Platform admin gets the cross-hotel usage rollup (conversations, requests, AI tokens per hotel).

### Privacy, retention, security
Minimal PII (name, room, optional phone). Retention defaults: messages 90d after conversation close; closed guest sessions 30d; AiRun 30d; WebhookEvent payloads 14d; per-guest-session hard delete for GDPR requests (button + AuditLog). Privacy notice + terms pages per hotel (template with hotel variables), marked "PILOT DRAFT — legal review required before production." Brakeman + bundler-audit in CI. Force SSL; signed cookies; CSRF on all non-webhook posts.

---

## Phased implementation (7 vertical slices — each ends deployed, tested, demoable on a phone)

Ordering fix from the judges: humans-first — the guest↔staff chat works before the AI ships, so the degradation message ("our team will reply") is never a lie.

**Slice 1 — Foundation, tenancy, hotel setup (demo: platform admin creates two branded hotels; hotel admin configures rooms/staff and downloads the QR sheet).**
`rails new hospello --database=postgresql` (Solid stack, importmap, Tailwind); auth generator + Pundit + roles; acts_as_tenant wiring **with the full isolation test suite from day one** (reflection test, cross-tenant 404 requests, grep-test); `/platform` hotels + first-admin CRUD with AuditLog; `/staff/settings` profile/branding (CSS custom properties + live preview), rooms (bulk add), departments/categories (seeded), staff invites; rqrcode QR + printable sheet; render.yaml deploy with `/up`, Sentry, heartbeat; CI (GitHub Actions: test, system test, rubocop, brakeman, bundler-audit). **Start WhatsApp onboarding paperwork now** (Meta app + test number; BSP decision per Blocking questions).

**Slice 2 — Guest web chat + reception inbox, human-only (demo: guest scans QR on a phone, identifies, messages; receptionist sees it flash up live and replies; guest returns next day to the same conversation).**
Branded landing + entry form (name, validated room, language, optional phone, consent) + cookie session; chat UI (mobile-first, quick-action chips, `dir=auto` bubbles, RTL chrome when ar, empty/loading/error states); conversation/message models with the partial-unique live-conversation index; staff inbox + detail + replies (same-language for now); Turbo Stream broadcasts + the full resilience layer (reconnect/visibilitychange resync, cable-down polling, server-side unread); rack-attack + `rate_limit` throttles; guest chrome i18n (bs/en/de/ar); "contact reception" quick action escalates. Acceptance #12 is structurally true from here on.

**Slice 3 — AI concierge, grounded (demo: "Wann gibt es Frühstück?" → accurate German answer from this hotel's KB only; unknown question → honest handoff offer; staff pause the AI, chat, hand back).**
KB CRUD with draft/publish; `Ai::Client` seam + `FakeClaude`; PromptBuilder with caching layout; GenerateReplyJob with per-conversation serialization + newest-message coalescing; guards (breaker, budget, AiRun, refusal handling); `escalate_to_staff` + `log_unanswered_question` tools; unanswered-questions inbox with one-click "Answer & add to KB"; AI pause/resume with transaction-time re-check; degraded-mode strings + dashboard banner; injection-corpus tests.

**Slice 4 — Service requests end-to-end (demo: "two towels at 6pm to 204" → AI gathers, summary card, guest confirms, exactly one request appears live on the board; staff accept → assign → complete; guest sees pending → in progress → done).**
Draft state machine + `propose/confirm_service_request` tools + confirmation cards + plain-text confirmation path + 30-min expiry; dedupe_key backstop; requests board with filters/search/overdue; status transitions + assignment + internal notes + RequestEvent timeline; guest-visible status updates (translated later — same-language now); NagJob; unverified badging.

**Slice 5 — Translation & language polish (demo: Arabic guest ↔ Bosnian receptionist, each reading their own language; a mangled room number demonstrably falls back to the original; staff UI switched to Bosnian).**
TranslateMessageJob both directions; digit guard with Eastern-Arabic normalization; 15s delivery budget with the delivery-claim column + watchdog; chip UI (original ↔ translated); lazy AI-message translation; budget ordering; staff UI locale files (bs, en); request `details_original` + staff-locale summary populated via the pipeline; guest status updates translated.

**Slice 6 — WhatsApp channel (demo: message the hotel's number → AI asks name + room, answers a KB question, takes a towel request → same dashboard, isolated per hotel; kill the web app's translation and watch WhatsApp behavior stay consistent).**
Provider port + MetaCloudProvider against the Meta test number; webhook controller (handshake, signature, WebhookEvent dedupe, <1s ack); ProcessInboundJob (routing, find-or-create session/conversation, race-safe); `set_guest_room` tool; delivery statuses; 24h-window guard + template path; welcome-template registry + opt-in send; channel config UI + status; onboarding docs (Hospello steps vs Meta/BSP steps clearly separated); first pilot hotel number flipped active when BSP/verification completes.

**Slice 7 — Analytics, onboarding checklist, retention, demo seed, hardening (demo: the full pitch — seeded Sarajevo hotel presented to a decision-maker; then revoke the Anthropic key in staging and watch every surface degrade gracefully and recover).**
Analytics pages (hotel + platform rollup, date ranges); readiness checklist; retention purges + GDPR delete; demo seed (`db/seeds/demo.rb`, `SEED_DEMO=1`): "Hotel Stari Grad Sarajevo" with rooms, 4 staff, departments/categories, ~20 KB entries (breakfast, checkout, restaurant, spa, pool, parking, Wi-Fi, policies, local recommendations), sample bs/en/de/ar conversations, requests in every status, ≥1 unanswered question; privacy/terms templates (marked for legal review); Mission Control mount at `/platform/jobs`; Sentry alert rules + QueueHealthJob; load smoke + PITR restore drill; pilot runbook (top-5 incidents with exact commands); final walkthrough of all 13 acceptance scenarios as guest *and* receptionist.

## Testing strategy

Minitest + fixtures; Capybara headless Chrome; WebMock `disable_net_connect!` (localhost allowed); CI on every push. All Anthropic access through `Ai::Client#chat(system:, messages:, tools:, model:) → Ai::Result`; tests inject `FakeClaude` scripted per test (canned replies, multi-step tool sequences, timeouts, 429/500, refusals). No VCR; one `LIVE_AI=1`-gated smoke test (real tool call + real `cache_read_input_tokens` assertion) run before releases.

- **Unit:** validations/enums; dedupe_key; UnansweredQuestion hash-upsert; digit guard corpus (incl. ٠-٩); circuit-breaker state machine (`travel_to`); AiUsageDay atomic upsert; budget thresholds; draft state machine.
- **Job:** reply happy path; coalescing; tool execution + idempotent retry; degradation → static message + escalation; translation fallback; delivery-budget timeout + claim (no double delivery).
- **Integration:** webhook signature accept/reject; **two deliveries of one provider message id → exactly one Message**; guest cookie lifecycle; throttle 429s; role boundaries.
- **Tenant isolation (dedicated, spec-required):** reflection test; every staff route as hotel-A with hotel-B IDs → 404; forged/other-hotel stream subscription rejected at Cable; foreign-tenant job raises; `without_tenant` grep-test over all of `app/`.
- **Concurrency:** parallel inbound for one message id → one row; parallel conversation creation → one live conversation; double tool call → one request; translation-vs-timeout → one delivery.
- **Injection:** corpus asserts no tool side effect without server validation; prompt-builder unit tests assert guest/KB text stays inside data tags.
- **System (Capybara):** scan → identify → chat → grounded answer (FakeClaude); two-browser guest↔staff live test; full request confirm flow; AI pause/takeover/resume; cable-down fallback (messages still appear via polling); RTL smoke (Arabic session renders `dir=rtl`).

## Render deployment & production readiness

Lean pilot topology (research-verified): **1 web service (starter, $7) + 1 Postgres (basic-256mb, $6 + ~$0.30/GB) + Cloudflare R2 (free) ≈ $13–16/mo**, Hobby workspace $0. Documented first bump: web → standard $25 (2GB) if RSS nears 512MB (WEB_CONCURRENCY stays 1 on starter, 2 on standard).

```yaml
# render.yaml
services:
  - type: web
    name: hospello
    runtime: ruby
    plan: starter                    # bump to standard if memory-tight (documented trigger: RSS alerts)
    buildCommand: ./bin/render-build.sh    # bundle install && rails assets:precompile && assets:clean
    preDeployCommand: bundle exec rails db:migrate   # zero-downtime release phase (paid instances)
    startCommand: bundle exec puma -C config/puma.rb
    healthCheckPath: /up
    envVars:
      - { key: DATABASE_URL, fromDatabase: { name: hospello-db, property: connectionString } }
      - { key: RAILS_MASTER_KEY, sync: false }
      - { key: ANTHROPIC_API_KEY, sync: false }
      - { key: WHATSAPP_APP_SECRET, sync: false }
      - { key: WHATSAPP_VERIFY_TOKEN, sync: false }
      - { key: WHATSAPP_ACCESS_TOKEN, sync: false }
      - { key: R2_ACCESS_KEY_ID, sync: false }
      - { key: R2_SECRET_ACCESS_KEY, sync: false }
      - { key: SOLID_QUEUE_IN_PUMA, value: "true" }
      - { key: WEB_CONCURRENCY, value: "1" }
      - { key: RAILS_MAX_THREADS, value: "5" }
      # plus: APP_HOST, AI_MODEL=claude-opus-5, TRANSLATION_MODEL=claude-haiku-4-5,
      # R2_ENDPOINT, R2_BUCKET, HEARTBEAT_URL, SENTRY_DSN, SMTP_* (Resend),
      # PLATFORM_ADMIN_EMAIL, PLATFORM_ADMIN_PASSWORD (sync: false)
databases:
  - name: hospello-db
    plan: basic-256mb                # PITR included on all paid tiers
```

`database.yml` production points primary/queue/cable/cache at the **same** `DATABASE_URL` with separate `migrations_paths` — connection budget ~15–30 of the plan's 100. Solid Queue runs in-Puma via the puma plugin; render.yaml carries a commented-out `worker` block (split trigger: sustained QueueHealth latency alerts, expected around hotel #5). Active Storage → R2 (never a Render disk — blocks zero-downtime + multi-instance). Seeds idempotent: platform admin `find_or_create_by` from env; demo hotel only with `SEED_DEMO=1`. Liveness: `/up` (web) + queue-originated heartbeat (a healthy web with a dead queue still pages). README documents: local setup, env vars, deploy steps, WhatsApp onboarding runbook, incident runbook. Scale-out path documented in order: standard web → separate worker → basic-1gb DB → PgBouncer (Solid Cable stays on 5432) → multi-instance.

## Risks & mitigations

1. **WhatsApp external lead time** (Meta review, display name, possible business verification; days–weeks). → Paperwork starts slice 1; product is complete on QR alone; dev runs on Meta's free test number; Coexistence offered for hotels' existing numbers; docs separate our steps from Meta's.
2. **AI hallucination / false confirmations.** → Published-KB-only grounding with citations audited per reply; tools as the only side-effect channel; pending-until-staff-acts wording enforced in prompt + UI; injection corpus in CI; `LIVE_AI` smoke before releases.
3. **Shared-QR identity spoofing.** → Honest unverified-by-design model, staff badges + verify action, privileged asks always escalate, per-IP/per-cookie throttles, session blocking, no sensitive data exists on the guest surface at all.
4. **Anthropic outage/latency on a guest-facing surface.** → 25s timeouts, breaker, pre-translated degraded strings (no API dependency), auto-escalation, staff chat unaffected, recovery visible in AiRun telemetry.
5. **Translation corrupting operational facts.** → Mechanical digit guard (with Eastern-Arabic normalization) + fallback-to-original; originals immutable and one tap away.
6. **Duplicate requests / replayed webhooks.** → Draft state machine + partial unique index, dedupe_key backstop, WebhookEvent + Message.external_id uniques — all exercised by concurrent-duplicate tests.
7. **Token cost runaway.** → Per-hotel daily budget with graceful budget-exhausted mode (translation protected to 100%), prompt caching, per-conversation serialization, message caps, throttles.
8. **Lost realtime updates.** → DB-first + after_commit broadcasts, visibilitychange resync, cable-down polling, server-side unread counts, zero-downtime deploys.
9. **Unattended pilot, silent failure.** → Queue-originated dead-man heartbeat, Sentry alert rules, QueueHealthJob, escalation nag emails to the hotel, incident runbook.
10. **Staff adoption.** → Nag emails when escalations sit unclaimed; overdue flags; sound + color for escalations; dashboard designed for a busy receptionist (two lanes, big touch targets, no AI jargon); readiness checklist prevents launching an unconfigured hotel.
11. **Postgres quadruple duty / in-Puma queue.** → Fine at pilot volume (measured connection budget); documented, pre-written split path before hotel #5.

## Acceptance scenario mapping

| # | Scenario | Where satisfied |
|---|---|---|
| 1 | Two hotels, isolated branding + data | Slice 1 (+ isolation suite) |
| 2 | Hotel configured, reusable QR downloaded | Slice 1 |
| 3 | Arabic guest, no phone, persistent web chat | Slice 2 |
| 4 | Grounded Arabic breakfast answer | Slice 3 |
| 5 | Unknown question → honest handoff | Slice 3 |
| 6 | Two towels → gather, summarize, confirm, ONE request | Slice 4 |
| 7 | Staff sees original + translation, accepts, assigns | Slices 4–5 |
| 8 | Guest sees in-progress, translated completion update | Slices 4–5 |
| 9 | Staff bs/en reply → guest reads Arabic; both visible | Slice 5 |
| 10 | Pause AI, manual handling, return to AI | Slice 3 |
| 11 | Branded WhatsApp → same dashboard, isolated | Slice 6 |
| 12 | AI/translation down → guest still reaches reception | Slice 2 structurally; Slice 3 degradation polish |
| 13 | Documented Render deploy | Slice 1, hardened Slice 7 |

## Verification (end-to-end, after each slice and at completion)

1. `bin/rails test && bin/rails test:system` green; rubocop/brakeman/bundler-audit clean in CI.
2. Deploy the slice to Render; hit `/up`; confirm heartbeat pings arrive; run the slice's demo script on a real phone.
3. Tenant-isolation suite green (non-negotiable gate for every slice).
4. Slice 3+: `LIVE_AI=1` smoke test against the real API (grounded answer + tool call + cache-hit assertion).
5. Slice 6: send a real WhatsApp message via the Meta test number → appears on the dashboard; duplicate webhook delivery → one message.
6. Slice 7: full 13-scenario walkthrough as guest and receptionist (two devices); staging chaos drill (revoke API key → degrade → restore → recover); PITR restore drill.

## Blocking questions (none block starting; needed at the marked slice)

1. **Anthropic API key** for dev + prod (needed by Slice 3). Assumed available via env.
2. **WhatsApp BSP decision** (needed before Slice 6 can go live with a real hotel number; dev proceeds on Meta's free test number regardless): recommended **360dialog** (~€49/mo/number, zero markup, hosted signup, Coexistence) vs Twilio (faster DX, ~$0.005/msg markup, different payload shape) vs Meta-direct (needs Hospello App Review first). Also: create Hospello's Meta Business Manager + app, and start Hospello's own business verification in parallel.
3. **Third-party free accounts** to create when convenient (Slice 1): Cloudflare R2, Sentry, healthchecks.io, Resend; and a **custom domain** decision (pilot can run on `*.onrender.com`).
4. **Render budget** confirmation: ~$13–16/mo lean, ~$31–47/mo with headroom (standard web + basic-1gb).
