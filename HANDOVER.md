# Handover

**Written for whoever picks this up next — human or agent, on any machine.**
Read [CLAUDE.md](CLAUDE.md) first if you haven't.

> **Keep this file true.** Update it in the *same commit* as the work it describes. A session can be
> cut off at any moment, and a stale handover is worse than none because the next agent trusts it.

---

## Status at a glance

| | |
|---|---|
| **Last updated** | 2026-08-10 |
| **Branch** | `main` |
| **Deployed** | Render (Frankfurt, free tier) — `/up` returns 200 |
| **Tests** | 373 unit/integration green · 17 system green except one known flake (see below) |
| **Progress** | Slice 1 complete · Slice 2 in progress (1 of 3 tasks done) · Slices 3–7 not started |

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
- Security: enforced CSP with a strict `script-src` and a session nonce, Rack::Attack throttles that
  resolve the real client IP behind Render's proxy, password minimum.
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

---

## What is in progress right now

**Slice 2 Task 2 — the chat itself.** A subagent was mid-implementation when this was written.

Its brief is `docs/plan/slice-2-tasks.md` (Task 2 section). It creates `Conversation` and `Message`,
the guest chat UI with quick-action chips built from the hotel's own request categories, live updates
over Action Cable, and the resilience layer.

**If the working tree has uncommitted migrations or half-written models when you arrive:** check
`git status` and `git log`. Nothing was pushed for this task. Either finish it against the brief or
`git checkout` the incomplete files and restart the task cleanly — both are fine, but decide
deliberately rather than building on top of an unknown half-state.

**Two decisions already made for this task**, so you don't re-litigate them:

1. `Guest::ChatsController#show` currently exists as a deliberately thin placeholder from Task 1. It
   is meant to be **replaced wholesale** by this task.
2. The brief asks for both a Turbo Stream broadcast *and* a custom `ConversationChannel`. **Pick one
   transport**, and make the ownership check real: either signed Turbo stream names (and test that a
   tampered name is rejected) or a custom channel that verifies the guest session owns the
   conversation in `subscribed`. The test must fail if the check is removed. Do not ship both.

---

## What to do next

1. **Finish Slice 2 Task 2** (chat) — see above.
2. **Slice 2 Task 3** — the reception inbox: staff see conversations live, open one, reply. Brief is
   in `docs/plan/slice-2-tasks.md`. **This is the milestone where the product becomes genuinely usable
   by a hotel**, humans only, no AI. Acceptance scenario 12 ("AI down, guest still reaches reception")
   becomes structurally true from here on.
3. **Slice 3** — the AI concierge, grounded strictly in the hotel's published knowledge base.
   Breakdown already written: `docs/plan/slice-3-tasks.md`.
4. **Slice 4** — service requests end to end. Breakdown written: `docs/plan/slice-4-tasks.md`.
5. Slices 5–7 (translation, WhatsApp, analytics/hardening) — specified in the plan, task breakdowns
   not yet written.

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
- **One system test file flakes ~4 runs in 10** (`platform_hotel_management_test.rb`) from a
  diagnosed Chrome click-delivery bug. It is not your fault, it is not a product bug, and a proposed
  fix was rejected as unproven. Don't let it block you; don't paper over it.
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
