# Incident runbook

Operational reference for whoever is on call for Hospello. Assumes the app
is deployed per the README's "Deploy to Render" section and you have
platform-admin access to the running instance plus Render dashboard access.

This is a living document — each later slice that introduces a new failure
mode (AI outage, translation failure, WhatsApp delivery) is expected to fill
in its own section below rather than leaving this generic.

## How the ops wiring fits together

- **`/up`** — Rails' built-in health check. Returns 200 if the process is up
  and answers HTTP requests. This is what Render's load balancer polls; it
  does **not** prove the background job pipeline is alive (see heartbeat,
  next).
- **`Ops::HeartbeatJob`** (`app/jobs/ops/heartbeat_job.rb`) — runs every 5
  minutes (`config/recurring.yml`, `production:` key) on the `low` queue.
  GETs `HEARTBEAT_URL` when it's set. It runs from the queue, not from a web
  request, on purpose: a Puma process can be fully alive and still answer
  `/up` while its Solid Queue supervisor is dead — only a job that actually
  executes proves the queue pipeline itself is alive. **Silence from this
  job is the alarm.** Point `HEARTBEAT_URL` at a dead-man's-switch monitor
  (e.g. healthchecks.io) configured to expect a ping at least every 5
  minutes and to page you when one doesn't arrive — the app itself sends no
  alert on a missed heartbeat, because if the queue is dead, no job
  (including an alerting one) can run to say so.
- **`Ops::QueueHealthJob`** (`app/jobs/ops/queue_health_job.rb`) — runs
  every 10 minutes on the `low` queue. Reports to Sentry
  (`Sentry.capture_message`, level `:error`) when
  `SolidQueue::FailedExecution.count > 0` or the oldest
  `SolidQueue::ReadyExecution` has been waiting longer than 5 minutes (a
  proxy for "a worker has stalled"). This needs `SENTRY_DSN` set to actually
  notify anyone — without it, `Sentry.capture_message` is a documented
  no-op and the job runs but tells nobody.
- **Mission Control – Jobs**, mounted at `/platform/jobs`, gated by the same
  session auth as the rest of `/platform` (a signed-in, active
  `platform_admin` — see `config/initializers/mission_control_jobs.rb`). The
  dashboard for everything below.

## Checking queue health right now

1. Sign in as a platform admin and visit `/platform/jobs`. Look at:
   - **Failed jobs** — anything here is `Ops::QueueHealthJob`'s first
     trigger condition. Click through to see the exception and backtrace.
   - **Queues** — `critical`, `ai`, `default`, `low` (see `config/queue.yml`
     for the concurrency each is allotted). A queue with a large or growing
     backlog and no visible worker activity is the second trigger
     condition.
   - **Processes** — the dispatcher, scheduler, and worker(s) that should
     be running inside the single Puma process (`SOLID_QUEUE_IN_PUMA=true`
     — see `config/puma.rb`). If this list is empty while `/up` still
     returns 200, that is exactly the split failure the heartbeat job
     exists to catch.
2. Alternatively, from a Render shell (paid instance types only —
   `bin/rails console` on the running service):
   ```ruby
   SolidQueue::FailedExecution.count
   SolidQueue::ReadyExecution.order(:created_at).first&.created_at
   SolidQueue::Process.pluck(:kind, :last_heartbeat_at)
   ```
3. If `Ops::HeartbeatJob` hasn't pinged `HEARTBEAT_URL` within your
   monitor's window: the queue pipeline is down while the web process is
   probably still up. Check the Render service's logs for the Puma boot
   sequence — `config/puma.rb`'s comments explain the two known ways this
   silently fails (`preload_app!` missing, or the plugin loading before
   `solid_queue_mode` is set) — then restart the service from the Render
   dashboard. A restart re-runs Puma's boot sequence and re-registers the
   Solid Queue processes; confirm via `/platform/jobs` → Processes.

## Reading Sentry

- Requires `SENTRY_DSN` set (optional — see the README's env var table).
  With it unset, errors never leave the Render logs.
- `config/initializers/sentry.rb`: `traces_sample_rate` is 0.1 (10% of
  transactions sampled for performance data — enough for p95/p99 trends
  without tracing every request), and `send_default_pii = false` — request
  params, cookies, query strings, and IP addresses are never attached to an
  event. Don't expect to see a guest's name or room number in a Sentry
  error; look at `request_id` instead (see below) and cross-reference logs.
- Every event and every `Ops::QueueHealthJob` alert should have enough
  context via `lograge`'s JSON log line for the same request
  (`config/initializers/lograge.rb`, production only) — each line carries
  `hotel_id`, `user_id`, and `request_id`. Search Render's log stream for
  the matching `request_id` to see the full request that triggered an
  error, and `hotel_id` to see whether an incident is scoped to one hotel
  or platform-wide.
- Triage order: check whether `hotel_id` is present and consistent across
  the errors you're seeing. A single `hotel_id` repeating means something
  specific to that hotel (bad data, a hotel-specific config value); `nil`
  or many different hotel_ids means a platform-wide issue.

## Suspending a hotel

Use this when a hotel needs to be taken offline immediately — a billing
issue, an abuse report, a pilot ending.

1. Sign in as a platform admin, go to `/platform/hotels`, open the hotel,
   click **Suspend**.
2. This sets `hotel.status = suspended` and writes an `AuditLog` row
   (`hotel.suspend`, actor + target recorded). No confirmation email is
   sent to the hotel — communicate directly if that's expected.
3. **Effect is immediate, with no separate step to revoke sessions.**
   `Staff::BaseController#require_staff_user` checks `Current.user.hotel&.active?`
   on every single request; the moment `status` flips to `suspended`, every
   signed-in staff member at that hotel gets `403 Forbidden` on their very
   next request — including requests from tabs that were already open.
   There is nothing further to do to lock them out.
4. To reverse: same page, **Reactivate** (`hotel.status = active`, another
   audited action). Staff regain access on their next request, same
   mechanism, no re-login needed if their tab is still open.

## Rotating a hotel's slug (a leaked printed QR code)

The QR code encodes `https://<APP_HOST>/h/<hotel.slug>` (see
`app/services/hotel_qr_code.rb`). A leaked or defaced printed card means
anyone with that image can reach the guest entry for that hotel — the fix
is to change the slug, which changes the URL every future QR points to.
This does **not** revoke anything already printed automatically; you still
have to reprint and redistribute the physical cards.

1. Sign in as a platform admin, go to the hotel's **Edit** page
   (`/platform/hotels/:id/edit`).
2. Change **Slug** to a new value — lowercase letters, numbers, and hyphens
   only (`Hotel::SLUG_FORMAT`); it's validated unique across all hotels.
   Save.
3. The old slug stops resolving to this hotel immediately (uniqueness +
   direct lookup by slug — there's no grace period or redirect from the old
   value).
4. Have the hotel's own staff go to **QR code** in their staff nav and
   re-download/re-print — the page always renders the code for the hotel's
   *current* slug, so no separate "regenerate" action exists; changing the
   slug is the regeneration.
5. Get the new card printed and distributed before removing/covering the
   old ones from rooms — there will necessarily be a window where the old
   physical card is now a dead link. Communicate that to the hotel in
   advance so their front desk isn't fielding confused guests.

## A guest asks to be forgotten

**The request arrives at the hotel, and the hotel forwards it to us.** Only a
platform admin can action one (`GuestErasurePolicy`), deliberately: a hotel
deleting a guest's transcript is indistinguishable, from the outside, from a
hotel destroying a complaint.

1. Sign in as a platform admin, open the hotel, click **Erase a guest's
   data** (`/platform/hotels/:id/guest_erasures`).
2. Find the stay. The search covers guest name, room number and phone
   number, which is all an erasure request ever arrives with. **A guest with
   two stays has two rows** — this app has no cross-stay guest record by
   design, so erase each one you find. Search by phone number where you have
   one; it is the only field that reliably spans stays.
3. Click **Erase…**. The confirmation names exactly what is about to go —
   how many conversations, how many messages, how many service requests will
   lose their guest. Read the numbers to the person asking if they want to
   know; they come from the same query that then does the deleting.
4. Confirm. It is **irreversible and there is no backup to restore from.**
5. The erasure writes an `AuditLog` row (`guest_data.erase`) naming you, the
   hotel, and counts of what it touched. **It deliberately does not record
   the guest's name or number** — the proof of an erasure must not be a copy
   of what it erased. If you need to tie a specific request to a specific
   audit row, keep that mapping in whatever system the request arrived in.

**What survives, and what to say if asked:** the hotel keeps its operational
record of any service the guest requested — with the guest's name, room,
words and identity stripped out of it, so the row says "Extra towels,
completed at 14:20" and nothing about who asked. That is the hotel's record
of work its own staff did, not the guest's personal data.

**One residual, and it is honest to state it:** a raw WhatsApp delivery that
never routed to a hotel (an unknown number, or one payload spanning two
hotels) is not deleted by an erasure, because it belongs to no single
hotel's records. Those rows are purged on their own 30-day clock, so an
erasure is complete within a month even in that case.

## The retention purge

`Retention::PurgeExpiredGuestDataJob`, every day at 03:20 (see
`config/recurring.yml`). Everything about *what* it deletes and *why* is in
`app/services/retention/policy.rb` — read that file, not the job.

**Checking it ran:** Mission Control at `/platform/jobs` → **Recurring
tasks** → `purge_expired_guest_data`. A missed run costs nothing: the next
one purges everything the missed one would have, because every cutoff is
computed from the moment the job runs rather than from the last run.

**If it has not run for weeks**, the queue is the problem, not the job — go
to "Checking queue health right now" above. Data kept past its window is a
liability, so this one is worth chasing rather than waiting out.

**Do not "fix" it by running a delete by hand.** Everything it does is
already one method per record type in that job; run the job itself
(`Retention::PurgeExpiredGuestDataJob.perform_now` from a console) rather
than composing a delete at a psql prompt, where there is no tenant scope,
no batching, and no second chance.

**If the policy's numbers ever change**, the guest-facing privacy notice in
all four languages must change with them in the same commit —
`test/i18n/privacy_notice_retention_test.rb` fails until it does, in both
directions. That test is not an obstacle to route around; it is the only
thing keeping a legal promise and the code that keeps it in the same story.

## Placeholder: AI outage

*To be filled in when the AI concierge ships (Slice 3). Expected content:
how to tell an Anthropic outage/rate-limit from an app bug, what degraded
behavior guests see (per the plan: pre-translated fallback strings, no API
dependency, auto-escalation to staff), where that shows up in Sentry/logs,
and how to confirm recovery.*

## Placeholder: translation failure

*To be filled in when translation ships (Slice 4–5). Expected content: how
a `translation_status: failed` message surfaces to staff and guests (per
the plan, delivery falls back to the original text with a pre-translated
"Message from our team:" prefix rather than blocking), how to tell a
one-off failure from a systemic one, and whether/how to retry.*

## Placeholder: WhatsApp delivery

*To be filled in when the WhatsApp channel ships (Slice 6). Expected
content: reading `WhatsappChannel#status`/`#last_error`, diagnosing a
24-hour-window `WindowClosed` failure vs. a genuine provider outage,
webhook signature failures, and what "the guest must message first" looks
like from the staff side. See `docs/whatsapp-onboarding.md` for the
account-level (not runtime) side of this channel.*
