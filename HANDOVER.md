# Handover

**Written for whoever picks this up next — human or agent, on any machine.**
Read [CLAUDE.md](CLAUDE.md) first if you haven't.

> **Keep this file true.** Update it in the *same commit* as the work it describes. A session can be
> cut off at any moment, and a stale handover is worse than none because the next agent trusts it.

---

## Status at a glance

| | |
|---|---|
| **Last updated** | 2026-08-10 (after Slice 3 — the AI concierge is complete) |
| **Branch** | `main` |
| **Deployed** | Render (Frankfurt, free tier) — `/up` returns 200 |
| **Tests** | 653 unit/integration green · 37 system green · rubocop and brakeman clean · **all of it green on CI** |
| **CI** | ✅ **green — for the first time in this repo's history.** See below; it was never a flake. |
| **Progress** | **Slices 1, 2 and 3 complete** · Slice 4 not started |

> ### The CI failure is fixed, and it was never a flake
>
> Every GitHub Actions run of this repo had failed, back to the first commit on 2026-08-07. Nobody
> had opened the Actions tab; three sessions reported "tests green" from **local** runs.
>
> The cause: every fixture signs in with `password123`, Chrome checks submitted passwords against
> its breach corpus, and on a hit it raises native "Change your password" UI that swallows every
> subsequent click. That is why the *first* form submit in a session always worked and everything
> after it died — and why it never reproduced locally: the check needs a live call to Google, so it
> silently does nothing wherever the network is closed. Four lines in
> `test/application_system_test_case.rb` fix it. Full account, including why the earlier
> click-delivery diagnosis looked right, is in [docs/plan/known-issues.md](docs/plan/known-issues.md).
>
> Two consequences worth knowing:
>
> - Because the job always stopped at the system-test step, `rubocop`, `brakeman` and
>   `bundler-audit` had **never once executed**. Rubocop and brakeman both had real findings by the
>   time anyone looked; both are clean now.
> - **Brakeman runs at `-w2`** (medium confidence and up). Its weak band includes "support for Rails
>   8.0.5.1 ends on 2026-10-07", which would otherwise fail every build from now on. That date is
>   real — see "What to do next".

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

**Slice 3 Task 1 — the knowledge base.** Complete. This is the corpus the concierge will be allowed
to answer from, and nothing else.

- `KbEntry` (`hotel`, `category`, `title`, `content`, `published`, `position`) — unpublished by
  default, capped at 2000 characters with a message a hotel manager can act on, titles unique per
  hotel so two hotels may each have a "Breakfast".
- `ordered` is `(position, id)`. The id tiebreak is **load-bearing, not tidiness**: the hotel's
  knowledge becomes a cached prompt prefix in Task 3, and the cache only hits on an exact match, so
  two entries sharing a position must come out in the same order every single build.
- `Hotel#published_kb_entries` is the one answer to "which entries may the model see".
- `/staff/kb_entries`: category tabs with counts, drafts marked in words, one-tap publish/unpublish,
  a live character count, and an empty state offering the topics guests actually ask about as
  starters that open the form already named. Read for all staff, write for hotel admins
  (`KbEntryPolicy`); publish/unpublish are audit-logged.

**Slice 3 Task 2 — the Anthropic seam and its test double.** Complete. Nothing in the app talks to a
model yet; this is the wall everything will talk *through*.

- `Ai::Client#chat(system:, messages:, tools:, model:, max_tokens:, effort:, timeout:)` → `Ai::Result`.
  It is the only file in the project that names `Anthropic::` at all.
- `Ai::Result` (`#text`, `#tool_calls`, `#stop_reason`, `#usage`, `#refusal?`, `#truncated?`) is a
  plain value object built from primitives, so `FakeClaude` produces *the same type* the real client
  does. That equivalence is what makes every AI test above this layer worth anything.
- `Ai::TimeoutError` / `Ai::RateLimitedError` / `Ai::ApiError`, all under `Ai::Error`.
  `ApiError#server_error?` is the distinction the Task 3 circuit breaker needs: a 5xx is worth backing
  off from, a 400 will fail identically forever and must never open the breaker for a whole hotel.
- **`FakeClaude` was written first, and is itself tested** (`test/services/ai/fake_claude_test.rb`).
  It scripts text, tool-call sequences, refusals, truncation, timeouts, 429s, 5xx, and usage with
  `cache_read_input_tokens`, and records every call so Task 3 can assert on the prompt that was
  actually built — including "hotel B's knowledge appears nowhere in hotel A's prompt".
- `config/initializers/ai.rb` holds the only model strings in the codebase (`AI_MODEL`,
  `TRANSLATION_MODEL`). Both documented in `.env.example`, `render.yaml` and `README.md`.
- `test/services/ai/live_smoke_test.rb` makes one real call — grounded answer, real tool call, and a
  non-zero cache read on the second call — and is skipped unless `LIVE_AI=1`. Run it before a
  release; it is the only thing that can catch the API changing under us.

**Slice 3 Task 3 — the concierge.** Complete. A guest asks in German and gets a German answer built
only from that hotel's published knowledge base; a question the hotel never wrote down is answered
honestly and passed to reception; a receptionist can pause the assistant and hand it back.

- `Ai::PromptBuilder` + `Ai::Prompt` — the grounding contract. Three system blocks ordered
  stable → volatile with the **one** cache breakpoint after the hotel's knowledge, the whole knowledge
  base in every prompt (no retrieval — see the class comment for why that is a feature), guest text
  sealed inside `<guest_message>` with `<` neutralised so it cannot close its own envelope, and
  history filtered to `.guest_visible`.
- `Ai::Tools` — `escalate_to_staff` and `log_unanswered_question`, the only way the assistant can
  change anything. The hotel and conversation come from the job's context and are **not arguments**,
  so a model naming a different hotel has nowhere to put the name. Failures come back as
  `tool_result` blocks, never exceptions.
- `Ai::Concierge` + `Ai::Outcome` — the bounded tool loop, usage summed across every call in the
  turn, and the judgement that a successful HTTP response is not necessarily a reply (`refusal?`,
  `truncated?`, blank text, and a loop that ran out of rounds all report "not a reply"). The
  `[kb: 12, 14]` citation marker is stripped before the guest sees anything and filtered against the
  hotel's real published entries.
- `Ai::GenerateReplyJob` — serialized per conversation (`limits_concurrency`), coalescing (each run
  records the guest message it handled, so a queued-behind job finds it dealt with), and the four
  guards. Enqueued from `Conversation#post_guest_message!`.
- `Ai::CircuitBreaker` (cache-backed, per hotel; timeouts and 5xx only), the pre-translated
  `config/locales/degraded.{bs,en,de,ar}.yml`, and the persistent staff banner
  (`StaffHelper#staff_ai_status_notice`).
- `AiRun` and `UnansweredQuestion`, with the budget guard counting a day in the *hotel's* timezone.
- `test/services/ai/injection_corpus_test.rb` — 17 real jailbreak shapes against the three
  guarantees code can actually make. It deliberately asserts nothing about how the model behaves.

**Two decisions in there that a reader might expect to go the other way**, both deliberate:

- Guards 1 and 2 (`ai_mode` paused, `hotel.ai_enabled` false) return in **silence** — no `AiRun`, no
  guest notice. The assistant being switched off is not a failure, and a "someone will reply
  personally" notice after every message is noise on a conversation a human is already working.
  `AiRun`'s status enum has no value for either case, which is the same reading.
- An assistant reply clears `staff_unread_count` exactly as a staff reply does: the guest has been
  answered, and a concierge that left every conversation flagged would recreate the front-desk load
  it exists to remove. A **degraded** notice deliberately does not clear it, because nothing answered
  the guest. If a pilot shows receptionists want to review every AI answer, this is the line to
  revisit — `Conversation#post_assistant_reply!`.

**Slice 3 Task 4 — the knowledge-gap workflow.** Complete. **Slice 3 is done**: a guest asks in
their own language and gets an answer built only from that hotel's published knowledge base; a
question the hotel never wrote down is answered honestly, passed to reception, and recorded; the
hotel sees it, writes the answer once, and it goes live.

- `/staff/unanswered_questions` — this hotel's open gaps, most-asked first, with the guest's own
  words alongside the normalised question, and a badged nav item because a screen nobody opens
  closes no loop.
- "Answer & add to the knowledge base" opens the `KbEntry` form already named, already ticked to go
  live, and carrying the gap through a validation failure (a hidden field, not a query parameter —
  a re-render is a POST, and a lost link would leave the gap open while the hotel believed they had
  just answered it). Saving links the entry and marks the question answered **only if the entry is
  actually published** — a gap answered into a draft is a gap no guest can tell was closed.
- Dismiss settles it without writing anything, and never deletes: the row goes on counting repeats,
  so a dismissal that turns out to be wrong stays visible instead of quietly reappearing as new.
- Read for every active staff member, write for hotel admins (`UnansweredQuestionPolicy`) — the same
  line the knowledge base draws, for the same reason.

---

## What to do next

1. **Slice 4 — service requests end to end.** The next slice, and the one that turns the concierge
   from something that answers into something that does. Breakdown already written:
   `docs/plan/slice-4-tasks.md`. Two things from Slice 3 are waiting for it specifically: the
   service-request tools slot into `Ai::Tools` alongside the two that exist (follow their shape —
   schema, server-side re-validation, `tool_result` on failure), and the plan's rule that **only a
   human may confirm** is now enforced only by the prompt, so Slice 4 is where it becomes structural.
2. **Bump Rails before 2026-10-07**, when 8.0.5.1 leaves support. Brakeman already says so on every
   run; it no longer fails the build (`-w2`), so this needs a human to actually schedule it.
3. Slices 5–7 (translation, WhatsApp, analytics/hardening) — specified in the plan, task breakdowns
   not yet written.

Still open, and now a real product question rather than a hypothetical one: the takeover notice
`pause_ai!` records is an **internal** note, so a guest whose conversation moves from the assistant
to a person is told nothing. That reads as deliberate from the guest's side (the chat simply carries
on) and there is a system test asserting it. Whether they should be told is a copy decision for a
human, not something to change on a hunch.

Slices 3 and 4 need an `ANTHROPIC_API_KEY`. The app boots and runs fine without one; only the
concierge and translation need it, and with no key `Ai::Client#chat` raises a plain `Ai::ApiError`
that the degradation path treats like any other AI failure — the guest gets "someone will reply
personally" and the conversation escalates, which is exactly what should happen.

**Run the live smoke test before a release.** `LIVE_AI=1 ANTHROPIC_API_KEY=... bin/rails test
test/services/ai/live_smoke_test.rb` makes one real call and is the only thing in this repository
that can catch the API changing under us — a mocked suite proves we send what we think we send, not
that anyone still accepts it. It has **never been run**: no key has been available in any session so
far, so the seam is verified against WebMock only.

---

## What will bite you

- **Read [docs/plan/engineering-rules.md](docs/plan/engineering-rules.md).** The single most common
  defect here, by a wide margin, is a test that passes against broken code — 20+ instances so far.
  Break the code and watch the test go red before you trust it.
- **Check [docs/plan/known-issues.md](docs/plan/known-issues.md) before fixing anything that looks
  broken.** Several things that look like bugs are deliberate and documented, and two plausible-
  sounding claims in there have been investigated and are false.
- **A green local run does not mean a green CI run.** Nobody checked the Actions tab for three days
  of work, and the whole build was red the entire time. Check it.
- **Don't remove the leak-detection settings** in `test/application_system_test_case.rb`. They look
  like belt-and-braces and they are not: without them every system test that signs in and then
  clicks fails on CI, and passes locally, which is the worst possible failure shape.
- **Internal notes and guest-visible messages live in the same table.** Any new read of `messages` on
  a guest-facing path must carry `.guest_visible` — there are exactly **four** such reads today and
  each has a test that goes red without it. `Message#visibility` documents the rule. The fourth is
  the least obvious: `Ai::PromptBuilder#history`. The model's output goes straight to the guest, so a
  note in the prompt is a leak with one extra step.
- **`max_tokens` caps thinking *and* visible text together** on current models, so a comfortable-
  looking cap can end a turn with `stop_reason == "max_tokens"` and little or no text — a successful
  HTTP 200 carrying nothing usable. `Ai::Result#truncated?` names it; treat it as a failure, never as
  a reply. Same for `#refusal?`. Anything that reads `result.text` without checking one of them will
  eventually post an empty message to a guest.
- **`Ai::Client` must be the only file that names `Anthropic::`.** If you find yourself rescuing an
  SDK exception class anywhere else, the seam has already leaked — add the mapping in the client
  instead. There is a test asserting all three mapped errors descend from `Ai::Error`.
- **No VCR, ever, for the AI layer.** A cassette recorded against one prompt keeps passing after the
  prompt changes, and a silently stale grounding prompt is the exact regression Slice 3 exists to
  prevent. Use `FakeClaude` above the seam and WebMock at it.
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
