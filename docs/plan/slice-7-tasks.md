# Slice 7 — Analytics, retention, the demo seed, and hardening

Demo at end of slice: **the full pitch.** A seeded "Hotel Stari Grad Sarajevo" — rooms, staff,
departments, ~20 knowledge entries, conversations in four languages, requests in every status —
presented to a decision-maker with nothing typed by hand. Then, in staging, revoke the Anthropic key
and watch every surface degrade in words the guest can act on, restore it, and watch everything
recover on its own.

This is acceptance scenario 13, and it is also the slice where scenarios 1–12 get walked end to end
as **both** guest and receptionist, on two real devices.

**This slice adds almost no new guest-facing behaviour.** Its job is to make what already exists
presentable, operable and lawful: what a hotel can see about its own usage, what happens to a
guest's data when they leave, what a new hotel has to have done before it goes live, and what the
person on call does at 03:00. Where a task here wants to change guest-facing behaviour, that is a
signal the earlier slice was incomplete — go fix it there rather than papering over it here.

## Already in place from Slices 1–6 — do not rebuild these

- `ai_runs`, written by both the concierge and the translator, with `[hotel_id, created_at]` and
  `[hotel_id, status, created_at]` indexes, `cited_kb_entry_ids`, `latency_ms`, and per-call token
  counts. **This is the raw material every analytics number in this slice comes from.**
- `AiRun.tokens_used_today` / `.budget_exhausted_for?` — the daily budget guard, summing raw rows in
  the hotel's own timezone. Task 1 changes what it reads, not what it means.
- `UnansweredQuestion` with `asked_count` — "what guests asked that this hotel never wrote down",
  already deduplicated and already counted.
- `ServiceRequest` with its full `TRANSITIONS` history in `request_events`, `acknowledged_at`,
  `completed_at` and `#overdue?` — every response-time number is derivable from rows that already
  exist.
- `Ops::HeartbeatJob`, `Ops::QueueHealthJob`, Mission Control mounted at `/platform/jobs`,
  `config/recurring.yml`, and `docs/runbook.md` with **three placeholder sections already reserved**
  (AI outage, translation failure, WhatsApp delivery). Fill those in; do not start a second runbook.
- `db/seeds/demo.rb` exists as a one-line stub loaded by `db/seeds.rb` when `SEED_DEMO=1`. The wiring
  is done; only the content is missing.
- The guest privacy notice and its pending-legal-review marker, in all four locales, with tests that
  read the locale files off disk rather than through `I18n.t`.
- `Hotel#status` (`active`/`suspended`) and the platform admin namespace, including the suspend path
  a retention purge will need to reason about.

---

### Task 1: The usage rollup — one row per hotel per day

**Why a rollup at all, when `ai_runs` already has everything:** an analytics page shows a month at a
time and a platform rollup shows every hotel at once. Both are `GROUP BY` over a table that grows by
one row per AI call forever, and the first hotel with a busy fortnight makes that page the slowest
thing in the app. A daily rollup is bounded by `hotels × days` and is the only table the charts read.

It also gives the budget guard something cheaper than `SUM` over today's raw rows — but **the guard's
meaning must not change**: a budget of zero still reads as "exhausted, no AI", not "unlimited".

**Files:**
- Create: `db/migrate/*_create_ai_usage_days.rb`, `app/models/ai_usage_day.rb`
- Create: `test/models/ai_usage_day_test.rb`, `test/fixtures/ai_usage_days.yml`
- Modify: `app/models/ai_run.rb`, `app/jobs/ai/generate_reply_job.rb`, `app/jobs/ai/translate_message_job.rb`

**Schema — `ai_usage_days`:**
`hotel_id` null: false FK · `on` date null: false (the date **in the hotel's own timezone** — a
Sarajevo hotel's day is not UTC's) · `kind` integer null: false (mirrors `ai_runs.kind`, so
"what did the concierge cost vs translation" stays answerable) · `runs`, `input_tokens`,
`output_tokens`, `cache_read_tokens`, `failures` all integer null: false default 0 ·
**unique index `[hotel_id, on, kind]`** · timestamps.

> **As built, one deviation:** the date column is **`usage_on`**, not `on`. `on` is close enough to
> SQL/Rails vocabulary that a bare `where(on: ...)` reads as a typo and `AiUsageDay#on` reads as a
> predicate; the extra four characters are worth it every time anyone reads a query.

- [x] **Step 1: Failing tests for the atomic upsert**

The whole table is one method, and it has one hard property: **two jobs finishing at the same instant
must both be counted.** A read-modify-write loses one of them, and the loss is invisible — a number
that is quietly 3% low forever is worse than one that is obviously broken.

So it is a single `INSERT ... ON CONFLICT (hotel_id, on, kind) DO UPDATE SET runs = ai_usage_days.runs
+ EXCLUDED.runs, ...` — Postgres does the addition, not Ruby. Test it by running the record twice and
asserting the sum, then by breaking it into a `find_or_initialize` + `save` and watching the test go
red. Cover: a first call creates the row; a second adds to it; a failed run increments `failures` but
still counts its tokens (a failed call is still billed); two kinds on one day are two rows.

- [x] **Step 2: Write it from where the tokens already are**

`Ai::GenerateReplyJob` and `Ai::TranslateMessageJob` both already build an `AiRun`. Record the
rollup in the same place — ideally from `AiRun` itself (an `after_create_commit`), so a future third
caller cannot forget it and the two cannot disagree. If you put it in the jobs instead, say why.

**The date is the hotel's, not the server's.** `AiRun.today_in(hotel.timezone)` already exists and
already gets this right; use the same source rather than a second reading of "today".

- [x] **Step 3: Point the budget guard at the rollup, unchanged in meaning**

`AiRun.tokens_used_today` becomes a rollup read. Its existing tests must pass **untouched** — if one
needs editing, the meaning changed and that is a product decision, not a refactor. Keep
`budget_exhausted_for?`'s zero-is-exhausted behaviour and its test.

- [x] **Step 4: Backfill, full suite, commit**

A rake task or a migration that fills `ai_usage_days` from existing `ai_runs`. Idempotent — running
it twice must not double the numbers, which is another use for the same upsert.

---

### Task 2: What a hotel can see about itself

**Files:**
- Create: `app/controllers/staff/analytics_controller.rb`, `app/views/staff/analytics/show.html.erb`
- Create: `app/services/analytics/hotel_report.rb`
- Create: `app/controllers/platform/analytics_controller.rb`, `app/views/platform/analytics/show.html.erb`
- Create: `test/controllers/staff/analytics_controller_test.rb`, `test/controllers/platform/analytics_controller_test.rb`
- Create: `test/services/analytics/hotel_report_test.rb`
- Modify: `config/routes.rb`, `app/helpers/staff_helper.rb` (nav), `config/locales/staff.{bs,en}.yml`

- [x] **Step 1: Decide what a hotelier actually asks, and compute only that**

The temptation here is a dashboard of everything measurable. Resist it: a page with twelve numbers on
it is a page nobody reads twice. The questions a hotel manager really has are:

- How many guests used it, and how many messages did that take?
- What did the assistant handle without a person, and what did it hand over?
- **What did guests ask that we could not answer?** (already in `unanswered_questions`, and the most
  actionable number on the page)
- How fast did we respond to requests, and how many went overdue?
- What is this costing us?

Everything else is decoration. If a number does not change what someone would *do*, leave it out.

> **As built, one deliberate departure from the list above:** *"What is this costing us?"* is **not**
> on the hotel's own page. A hotel does not pay per token — it pays Hospello — so a token count is a
> number it cannot act on, and by this section's own test it does not belong. What it *can* act on is
> proximity to the daily budget that will silence its assistant, so the page shows
> `budget_used_fraction` instead. Tokens move to the platform page, where they really are the cost
> driver. The page is also **hotel-admin only**: a receptionist reading "how often did the assistant
> have to hand over to us" is reading a page about their own performance, and that is a conversation
> a manager should choose to have rather than one the software starts.

`Analytics::HotelReport` takes a hotel and a date range and returns one value object. Not a
controller full of queries: the platform rollup asks the same questions of every hotel, and two
implementations of "how many escalations" will disagree within a month.

- [x] **Step 2: Date ranges that cannot lie**

Every range is in the **hotel's own timezone**, and the page says which range it is showing in words.
The traps, each of which has produced a wrong chart in some other product:

- "Last 30 days" that silently includes a partial today, next to a total that does not.
- A range whose end is before its start — clamp it, do not raise.
- A range so wide it scans the whole rollup — cap it, and say so on the page.

Test the boundaries explicitly with `travel_to`: a run at 23:59 in Sarajevo belongs to that day, not
to UTC's next one.

- [x] **Step 3: The platform rollup**

Every hotel, one row each, for the person who runs Hospello. Lives in `Platform::` — which is the one
namespace allowed to cross tenants, and the tenancy grep test already knows it. Reads the same
`Analytics::HotelReport`, so a hotel and the platform never see different numbers for the same thing.

> **As built, one thing the brief did not anticipate:** a report is *lazy*, so building one inside
> `with_tenant` in the controller and reading it in a template ran every query outside the tenant and
> raised `NoTenantSet` — the fail-closed behaviour catching a real mistake. Fixed in the report rather
> than at the call site: each reader now runs inside its own hotel's tenant (`#for_hotel`), so a
> report is safe to read anywhere, and `#top_unanswered` materializes rather than handing back a
> relation. `with_tenant` narrows to one hotel and never widens past one, so it is not one of the
> escape hatches the tenancy tripwire polices.

- [x] **Step 4: Isolation, and a test that would catch the obvious mistake**

The staff page must be unable to show another hotel's numbers — which is structural, since the
report is built from `Current.hotel`. Prove it anyway with a second hotel that has *deliberately
different* numbers, so a report accidentally scoped to "all hotels" is visibly wrong rather than
coincidentally right. Suspended hotels appear in the platform rollup: "which hotels stopped using
it" is exactly what that page is for.

---

### Task 3: Retention and the right to be forgotten

**The one task in this slice with legal weight**, and the one where a bug is not recoverable in
either direction: data kept too long is a liability, and data deleted wrongly is gone.

**Files:**
- Create: `app/jobs/retention/purge_expired_guest_data_job.rb`, `app/services/retention/policy.rb`
- Create: `app/services/retention/guest_erasure.rb`
- Create: `test/jobs/retention/purge_expired_guest_data_job_test.rb`, `test/services/retention/guest_erasure_test.rb`
- Modify: `config/recurring.yml` (the entry its comment already reserves), `docs/runbook.md`,
  `app/controllers/platform/` (the erasure entry point), the privacy notice copy in all four locales

- [ ] **Step 1: Write the policy down before writing any code that deletes**

`Retention::Policy` is a plain object naming, per record type, how long it is kept and why. It exists
so the answer to "why is this row still here?" is a file rather than an archaeology exercise, and so
the privacy notice and the purge job read the **same** numbers — a notice promising 90 days beside a
job that keeps 180 is worse than either alone.

Decide, and write the reasoning next to each: guest sessions and their conversations; messages;
service requests (a hotel has a real operational reason to keep these longer than a chat);
`ai_runs`; `webhook_events`; `unanswered_questions` (arguably not personal data at all once the
question is generalized — say so if you conclude that).

- [ ] **Step 2: Purge, in batches, tenant by tenant**

`TenantFree`, iterating hotels with `with_tenant` — the same shape `Ai::TranslationWatchdogJob`
already uses. In batches, because the first purge on a year-old database is the largest delete this
app will ever do and it must not hold a transaction open across all of it.

Test what was kept as carefully as what was deleted. A purge test that only asserts rows disappeared
passes just as happily when it deletes everything.

- [ ] **Step 3: Erasure on request, for one guest**

A named request from an individual, which is a different operation from a scheduled purge: it is
immediate, it is for one person, and it has to be **auditable** — the one record that must survive is
the fact that the erasure happened.

Anonymize rather than delete where a row is load-bearing for the hotel's own records (a completed
service request is the hotel's operational history, not just the guest's data): clear the name, the
phone, the room, the message bodies; keep the shape. Say which fields, in a comment, and why each.

Guarded by the platform admin namespace, and **irreversible** — so the confirmation must name what
is about to be destroyed rather than asking "are you sure?".

- [ ] **Step 4: The notice must match the code**

Update the privacy notice in all four locales to state the real retention periods, and write a test
that reads `Retention::Policy` and asserts the numbers appear in the copy. That test is the point of
the task: it is what stops the two from drifting the next time someone changes one.

---

### Task 4: The demo seed

**Files:**
- Modify: `db/seeds/demo.rb` (the wiring and the `SEED_DEMO=1` gate already exist)
- Create: `test/seeds/demo_seed_test.rb`

- [x] **Step 1: One hotel, complete, credible, and safe to show**

"Hotel Stari Grad Sarajevo": rooms across two floors, 4 staff (one hotel admin, three reception),
departments and request categories, **~20 knowledge entries** covering what guests actually ask —
breakfast, check-out, restaurant, spa, pool, parking, Wi-Fi, smoking and pet policies, airport
transfer, and a handful of genuinely useful local recommendations.

The knowledge base is the part that decides whether the demo lands. Twenty thin entries read as a
template; twenty specific ones ("breakfast is served in the Ćevabdžinica restaurant from 07:00 to
10:30, and we can pack one to take away if you are leaving early") read as a real hotel.

- [x] **Step 2: Conversations that show the product, including its failures**

Sample conversations in **bs, en, de and ar** — the Arabic one matters most, because it is the only
way an RTL rendering problem is visible before a demo rather than during one. Requests in **every**
status, including one overdue and one declined. At least one unanswered question, so the knowledge-gap
screen is not empty. At least one conversation showing the assistant handing over to a person: a demo
that only shows the happy path invites exactly the question it does not answer.

- [x] **Step 3: Idempotent, and impossible to run against real data**

Running it twice must not produce two hotels — key on the slug. **`SEED_DEMO=1` and nothing else**,
never a default, and the seed should refuse outright if the database already contains a hotel it did
not create. Someone will run this against production eventually; make that safe rather than
unlikely.

- [x] **Step 4: A test that runs the seed**

> **As built, two bugs the seed found in code that was already shipped** — which is the argument for
> a seed test that actually loads the file rather than checking it parses:
> - `UnansweredQuestion.record!`'s "a repeat counts itself in" rescue only worked *outside* a
>   transaction. Postgres aborts the whole transaction on a constraint violation, so the recovery's
>   own `find_by!` failed too. Fixed with a savepoint (`requires_new: true`). Nothing in the app was
>   a caller inside a transaction, which is exactly why nothing caught it.
> - `AiRun`'s `after_create_commit` wrote the rollup with no tenant set, because a commit fires
>   where the transaction ends rather than where the record was built — so wrapping the seed in one
>   transaction lost all 125 rollup writes to `NoTenantSet`. Fixed in `AiUsageDay.record!`, which now
>   takes its tenant from the run. Then removing the seed's workaround mattered too: with the
>   callbacks working, an explicit `rebuild_for` alongside them *replaced* a day's counters while the
>   callbacks *added* to them, and every number came out exactly doubled.

Not "the file parses" — actually load it and assert the shape a demo depends on: the hotel exists,
the KB has entries in more than one language, there is a request in each status, the RTL conversation
exists. A demo seed that broke three slices ago and nobody noticed is the normal failure mode here.

---

### Task 5: Hardening, and the walkthrough that ends the project

**Files:**
- Create: `docs/pilot-readiness.md`
- Modify: `docs/runbook.md` (its three reserved placeholder sections), `README.md`
- Create: `test/system/` additions only if the walkthrough finds something

- [ ] **Step 1: The readiness checklist**

What must be true before a hotel goes live, as a list someone can actually tick: branding set, rooms
loaded, at least N knowledge entries published, request categories configured, staff invited, QR code
printed and physically placed, privacy notice reviewed, WhatsApp connected (or explicitly deferred).

Consider making it a screen rather than a document — a checklist a hotel can see its own progress
against is worth more than one in a repository they will never open. If it stays a document, say why.

- [ ] **Step 2: Fill in the runbook's three placeholders**

AI outage, translation failure, WhatsApp delivery — each with **exact commands**, not descriptions of
commands. The test of a runbook is whether someone who did not build the system can follow it at
03:00, so write it for that person: what they will see, what to check first, what to do, and what
"fixed" looks like.

- [ ] **Step 3: The chaos drill, actually run**

In staging: revoke the Anthropic key, watch the circuit breaker open, confirm the guest gets the
pre-translated fallback and reception gets the persistent notice, restore the key, and confirm
recovery **without a deploy**. Write down what actually happened, including anything slower or
uglier than expected. A drill that is described but not run is worth nothing, and this one has been
specified since Slice 1.

- [ ] **Step 4: The PITR restore drill**

Restore the production database to a point in time on a throwaway instance and confirm the data is
there. Record how long it took — that number is the real RPO/RTO, and nobody knows it until someone
does it once.

- [ ] **Step 5: All 13 acceptance scenarios, as guest *and* receptionist, on two devices**

The final gate. Two real devices, both roles, every scenario in the plan's table. Anything that
fails is fixed **in the slice that owns it**, not patched here.

- [ ] **Step 6: `LIVE_AI=1`, at last**

This smoke test has never run in any session, because no session has had an `ANTHROPIC_API_KEY`. It
asserts a real grounded answer, a real tool call, and a real `cache_read_input_tokens` value — which
is the only thing that has ever verified prompt caching actually works. **Run it before calling this
slice done**, and if it fails, that is a finding about Slices 3–5, not about this task.

---

## Traps worth knowing before you start

- **A rollup that loses a concurrent write is invisible.** Postgres does the addition, in one
  statement, or the numbers are quietly wrong forever. This is the same reasoning as
  `Message#claim_translation!` and `#claim_delivery!`, applied to arithmetic.
- **Every date is the hotel's date.** A Sarajevo hotel's day ends at 23:59 Sarajevo time. `AiRun
  .today_in` already gets this right; anything that reads `Date.current` here is a bug waiting for a
  guest to message at midnight.
- **A purge test that only asserts deletion passes when it deletes everything.** Assert what
  survived, in the same test.
- **The privacy notice and the retention job must read the same numbers.** Two sources of truth about
  a legal promise is the one kind of drift that cannot be fixed retroactively.
- **Do not add guest-facing behaviour here.** If a demo reveals a gap, fix it in the slice that owns
  it — this slice's job is to make the product presentable and operable, and a change made here has
  none of that slice's tests around it.
- **The demo seed will eventually be run against production.** Make that safe rather than unlikely.
- **`LIVE_AI=1` has never run.** Everything believed about prompt caching, real tool-call shapes and
  real token accounting rests on tests against `FakeClaude`. Treat its first run as a source of
  findings, not as a formality.
