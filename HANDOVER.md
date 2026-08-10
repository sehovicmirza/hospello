# Handover

**Written for whoever picks this up next — human or agent, on any machine.**
Read [CLAUDE.md](CLAUDE.md) first if you haven't.

> **Keep this file true.** Update it in the *same commit* as the work it describes. A session can be
> cut off at any moment, and a stale handover is worse than none because the next agent trusts it.

---

## Status at a glance

| | |
|---|---|
| **Last updated** | 2026-08-10 (after Slice 2 Task 3 — Slice 2 complete) |
| **Branch** | `claude/continue-ai-agent-work-bq59gm` |
| **Deployed** | Render (Frankfurt, free tier) — `/up` returns 200 |
| **Tests** | 475 unit/integration green · 28 system green locally (four consecutive clean runs) · rubocop and brakeman clean |
| **CI** | ❌ **red, and has been on every run since the repo's first** — pre-existing, not this work. See below. |
| **Progress** | Slices 1 and 2 complete · Slices 3–7 not started |

> ### Read this before trusting "tests green"
>
> Every GitHub Actions run of this repo has failed, back to 2026-08-07. Earlier handovers reported
> green suites; those were **local** runs and nobody had opened the Actions tab. The failing step is
> always `bin/rails test:system`, always the same three tests in `platform_hotel_management_test.rb`,
> and always the Chrome click-delivery flake already diagnosed in
> [docs/plan/known-issues.md](docs/plan/known-issues.md) — where new evidence from this session is now
> recorded, including the fact that CI runs the system suite against a *different Chrome build* than
> the one its own setup step installs.
>
> Because the job stops at that step, the `rubocop` and `brakeman` steps had **never once run**. Both
> had accumulated real findings by the time this session checked; both are clean now.
>
> `bin/rails test` passes on CI. This work is covered by it.

---

## What is finished and verified

**Slice 1 — foundation, tenancy, hotel setup.** All seven tasks complete and reviewed.

- Multi-tenancy via `acts_as_tenant` with `require_tenant = true` — unscoped queries **raise**.
  Backed by a dedicated isolation suite and a grep tripwire over all of `app/`.
- Authentication (Rails 8 generator, no Devise), roles `platform_admin` / `hotel_admin` / `staff`,
  Pundit policies.
- Platform admin: create hotels, create each hotel's first admin, suspend/reactivate, all audit-logged.
- Hotel admin: branding (colours drive the guest UI through CSS custom properties, with text contrast
  chosen by real WCAG contrast ratios), logo and welcome image, rooms with bulk paste, departments,
  request categories, staff accounts.
- One reusable QR code per hotel — SVG/PNG download plus a printable A5 sheet with instructions in
  four languages.
- Ops: Solid Queue in-process (no Redis), recurring jobs, a queue-originated dead-man heartbeat,
  Sentry, lograge, Mission Control at `/platform/jobs` gated by platform-admin auth.
- Security: enforced CSP with a strict `script-src` and a per-request nonce, Rack::Attack throttles
  that resolve the real client IP behind Render's proxy, password minimum.
- CI (GitHub Actions), `.env.example`, `README.md` deploy walkthrough, `docs/runbook.md`,
  `docs/whatsapp-onboarding.md`.

**Slice 2 Task 1 — guest identity.** Complete, reviewed twice, fix round applied and re-reviewed.

- `GET /h/<slug>` — the route the printed QR code actually points at. It did not exist before this
  task; the path was a bare string literal in three unrelated files. Now pinned by tests, so a rename
  goes red instead of turning printed room cards into dead paper.
- Hotel-branded landing page + entry form: full name, room number validated against the hotel's active
  rooms, language (auto-detected from `Accept-Language`, four options), optional phone, consent.
- `GuestSession` with a signed httponly cookie; only a SHA-256 digest is stored. 7-day rolling expiry
  capped at 21 days. Return visits skip straight back into the chat.
- Guest chrome in **bs / en / de / ar** with correct RTL (real geometry tests, not just `dir="rtl"`).
- Identity is **always unverified**, enforced on the write path, not just at creation.
- A suspended hotel refuses guests on *every* request, not only at signup.

**Slice 2 Task 2 — the chat.** Complete and pushed; review in progress at time of writing.

- `Conversation` and `Message`, with the two guarantees enforced by Postgres rather than by care: a
  partial unique index giving **one live conversation per guest**, and a `client_message_id` unique
  index giving **exactly one message per send** (a guest double-tapping send on a slow phone is the
  real scenario). `Conversation.live_for` rescues `RecordNotUnique` and re-finds.
- Guest chat UI: message bubbles, quick-action chips built from the hotel's own active request
  categories that **prefill the composer without sending**, and the empty/sending/failed states.
- Live updates over Action Cable plus the resilience layer — on disconnect, reconnect and
  `visibilitychange` it resyncs over HTTP from `?after=<id>`, and polls while the cable is down. The
  rule encoded: the database is the truth, broadcasts are an enhancement.
- **Fixed a pre-existing bug that had disabled all JavaScript on the guest surface.** The CSP nonce
  generator used `request.session.id.to_s`, which is empty on guest requests because guests never
  touch Rails' session — so the inline importmap and Stimulus loader were blocked on every guest
  page. Nothing caught it because the only CSP test drove the *staff* side. Now a per-request
  `SecureRandom` nonce. Verified: restoring the old generator fails the guest chat tests.

**Slice 2 Task 3 — the reception inbox.** Complete. **Slice 2 is done**: a guest scans a QR code,
chats in their own language, and a receptionist sees it live and replies. No AI anywhere in the path,
which is the point — acceptance scenario 12 ("AI down, guest still reaches reception") is structurally
true from here on.

- `messages.visibility` (`guest_visible` / `internal`) — internal notes share the messages table so
  the staff transcript reads as one chronological story. The default is the safe one, visibility is
  frozen after creation, and only staff-authored roles (`staff`, `system`) may be internal.
- **All three guest-facing message reads now filter on it**: `Guest::ChatsController#show`,
  `Guest::MessagesController#index` (the resync endpoint), and `Conversation#broadcast_new_message`.
  Each of the three has a test that goes red when its filter is removed — verified by removing them.
- `Conversation`: `post_internal_note!`, `pause_ai!` / `resume_ai!` (internal system notice naming
  the acting user), `mark_read_by_staff!`, `needs_attention` / `settled` / `inbox_order` /
  `matching` scopes, `LIVE_STATUSES` + `#live?`.
- A staff reply to a **resolved** conversation reopens it. When the guest has already started a newer
  one, reopening would break the one-live-conversation index — that case raises
  `Conversation::SupersededConversation` and rolls the reply back rather than leaving it in a
  transcript the guest will never open again.
- The inbox itself: `/staff/conversations` with all / needs-attention / resolved tabs, search by
  guest name or room number, needs-attention rows sorted first and marked in **words** as well as
  colour, the UNVERIFIED badge on every row, and a server-computed unread badge in the nav.
- The conversation detail view: full transcript, the internal-note boundary (distinct background,
  lock glyph, and the literal sentence "Internal note — the guest cannot see this"), **two separate
  composers** rather than one with a mode toggle, the Pause AI / Return toggle, and Mark resolved.
- `HotelInboxChannel` — the staff-side counterpart of `ConversationChannel`. It re-checks that the
  subscriber is active staff of an unsuspended hotel on subscribe, because a cable connection
  outlives the request that opened it.
- Live updates are a Turbo 8 **morphing page refresh** broadcast to `[hotel, :inbox]`, not targeted
  stream appends: the list and the detail view are different DOM shapes reacting to the same event,
  and re-rendering from the server is what keeps every count server-computed.
  `inbox_resilience_controller.js` re-visits the page on reconnect/visibilitychange and polls every
  60s while the cable is down.
- `test/system/guest_staff_live_test.rb` — **the test that proves the slice**. Two real browsers: the
  guest posts and the receptionist's page updates itself, then the receptionist replies and the
  guest's page updates itself. A second test in the same file writes an internal note while the guest
  sits on a live chat and proves it never arrives.

---

## What to do next

1. **Get CI green** — or decide out loud that it stays red and why. It is one pre-existing flaky file
   (see the box at the top and `docs/plan/known-issues.md`), and while it is red nothing downstream
   of it in the workflow runs at all. This is small and it unblocks every future session's ability to
   trust a green check.
2. **Slice 3** — the AI concierge, grounded strictly in the hotel's published knowledge base.
   Breakdown already written: `docs/plan/slice-3-tasks.md`.
3. **Slice 4** — service requests end to end. Breakdown written: `docs/plan/slice-4-tasks.md`.
4. Slices 5–7 (translation, WhatsApp, analytics/hardening) — specified in the plan, task breakdowns
   not yet written.

When Slice 3 arrives, two things this task deliberately left for it: `ai_mode` is written by the
staff toggle but **nothing reads it yet**, and the takeover notice it records is an internal note.
Whether the guest should also be told "you are now speaking to reception" is a product-copy decision
that only makes sense once there is an assistant to be handed over from.

Slices 3 and 4 need an `ANTHROPIC_API_KEY`. The app boots and runs fine without one; only the
concierge and translation need it.

---

## What will bite you

- **Read [docs/plan/engineering-rules.md](docs/plan/engineering-rules.md).** The single most common
  defect here, by a wide margin, is a test that passes against broken code — 20+ instances so far.
  Break the code and watch the test go red before you trust it.
- **Check [docs/plan/known-issues.md](docs/plan/known-issues.md) before fixing anything that looks
  broken.** Several things that look like bugs are deliberate and documented, and two plausible-
  sounding claims in there have been investigated and are false.
- **One system test file flakes** (`platform_hotel_management_test.rb`) from a diagnosed Chrome
  click-delivery bug — ~4 runs in 10 locally for an earlier session, but **100% of runs on GitHub
  Actions**, where it is the sole reason CI is red. It is not your fault and it is not a product bug;
  a proposed fix was rejected as unproven. Don't paper over it — `known-issues.md` now carries a
  concrete, untested lead (CI's Chrome on PATH is a different build from the one its setup step
  installs).
- **A green local run does not mean a green CI run.** Nobody had checked the Actions tab for three
  days of work. Check it.
- **Internal notes and guest-visible messages live in the same table.** Any new read of `messages` on
  a guest-facing path must carry `.guest_visible` — there are exactly three such reads today and each
  has a test that goes red without it. `Message#visibility` documents the rule.
- **`.superpowers/` is gitignored** — it is agent scratch. Everything a new session actually needs is
  in `docs/plan/` and this file. If you produce something durable, put it in `docs/`, not there.
- **Never commit `config/master.key`.** It was accidentally committed once early on and had to be
  purged from history before the first push. The ignore rule is in place; don't defeat it.

---

## Environment

Local setup, environment variables, and the full Render deploy walkthrough are in
[README.md](README.md). Incident procedures are in [docs/runbook.md](docs/runbook.md).

**You do not need any secret to develop or test.** `config/master.key` is gitignored and absent from
a fresh clone — that is correct and expected. Nothing in `app/`, `config/`, or `lib/` reads
`Rails.application.credentials`, and the full suite passes with the key missing (verified). You only
need real secrets to *deploy*, and those live in Render's dashboard, not in the repo. If something
appears to demand a master key, that is a bug introduced by whoever added the credentials read — do
not work around it by asking for the key.

A database is required. `bin/setup` creates and migrates it; `DATABASE_URL` is honoured if your
environment provides Postgres that way.

```bash
bin/setup                 # install, create and migrate the database, seed
bin/dev                   # run locally
bin/rails test            # unit + integration
bin/rails test:system     # browser tests (headless Chrome)
```

Deployment is `render.yaml` (Blueprint). Migrations and seeds run in `bin/render-build.sh` because
`preDeployCommand` requires a paid instance type. Everything is on free tiers; the plan documents the
upgrade order and the trigger for each step.
