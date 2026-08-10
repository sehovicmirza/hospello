# Slice 4 — Service requests, end to end

Demo at end of slice: a guest types "can I get two extra towels around 6pm". The concierge notices
what's missing, asks one question, shows a summary card, waits for the guest to confirm, and only
then creates **exactly one** request. It appears on the reception board immediately. A receptionist
accepts it, assigns it, completes it — and the guest sees it move from pending to in progress to
done, never being told anything was confirmed before a person actually confirmed it.

This is the slice where the product's central promise is either kept or broken: **the assistant may
gather and propose, but only a human may confirm.** Acceptance scenarios 6, 7 and 8 live here.

In place from Slices 1–3: hotels with departments and `RequestCategory` rows carrying
`detail_fields`; `GuestSession`, `Conversation` (with `ai_mode`), `Message`; the guest chat and its
resilience layer; the reception inbox with live updates and AI pause/resume; `Ai::Client` +
`FakeClaude`; `Ai::PromptBuilder` with its cached knowledge block; `Ai::GenerateReplyJob` with
per-conversation serialization, the circuit breaker, the budget guard and `AiRun` telemetry; the
`escalate_to_staff` and `log_unanswered_question` tools; `AuditLog`.

---

### Task 1: The draft state machine — gather, then confirm, then create

**Why a draft table rather than a boolean:** the guest and the assistant may exchange several turns
before a request is complete ("two towels" → "when?" → "6pm"). Something has to hold the partial
request across those turns, expire it if the guest wanders off, and guarantee that a retried tool
call cannot produce a second request. A row with a state does all three; a flag on the conversation
does none of them.

**Files:**
- Create: `db/migrate/*_create_service_request_drafts.rb`, `db/migrate/*_create_service_requests.rb`, `db/migrate/*_create_request_events.rb`
- Create: `app/models/service_request_draft.rb`, `app/models/service_request.rb`, `app/models/request_event.rb`
- Create: `app/jobs/service_requests/expire_drafts_job.rb`
- Create: `test/models/service_request_draft_test.rb`, `test/models/service_request_test.rb`
- Create: `test/fixtures/service_requests.yml`, `test/fixtures/service_request_drafts.yml`
- Modify: `config/recurring.yml`, `app/models/conversation.rb`

**Schema — `service_request_drafts`:** `hotel_id` null: false · `conversation_id` null: false FK ·
`request_category_id` FK nullable (unknown until the guest says what they want) ·
`details` jsonb null: false default `{}` · `status` integer null: false default 0
(`gathering: 0, awaiting_confirmation: 1, confirmed: 2, discarded: 3, expired: 4`) ·
`expires_at` datetime null: false · timestamps.

**The index that makes the guarantee real:**
```ruby
add_index :service_request_drafts, :conversation_id, unique: true,
  where: "status IN (0, 1)", name: "index_one_live_draft_per_conversation"
```
One live draft per conversation, enforced by Postgres rather than by application care.

**Schema — `service_requests`:** `hotel_id` null: false · `conversation_id` FK · `guest_session_id`
FK · `room_id` FK · `request_category_id` FK null: false · `department_id` FK (denormalized from the
category so a later category edit doesn't rewrite history) · `summary` string null: false ·
`details` jsonb null: false default `{}` · `details_original` text · `original_locale` string ·
`requested_for_at` datetime · `status` integer null: false default 0
(`new: 0, accepted: 1, in_progress: 2, completed: 3, declined: 4, cancelled: 5`) ·
`priority` integer null: false default 0 (`normal: 0, high: 1`) · `assigned_to_id` FK ·
`source` integer null: false default 0 (`ai: 0, staff: 1`) · `channel` integer null: false ·
`dedupe_key` string null: false — **unique index** · `acknowledged_by_id` FK ·
`acknowledged_at`, `completed_at` datetimes · timestamps.
Index `[hotel_id, status, created_at]` for the board.

**Schema — `request_events`:** `hotel_id` null: false · `service_request_id` null: false FK ·
`user_id` FK nullable · `kind` integer null: false (`status_change: 0, assignment: 1, note: 2`) ·
`from_status`, `to_status` integers · `note` text · timestamps.
Internal notes and the visible status history share one table because they are the same thing to a
receptionist reading the history — with `kind` deciding what the guest may be told.

**Interfaces produced:**
- `ServiceRequestDraft#ready?` — true when every field named by the category's `detail_fields` is
  present in `details`. This is what decides whether the assistant asks another question.
- `ServiceRequestDraft#missing_fields` — the ordered remainder, so the assistant asks for one thing
  at a time and always the same thing first.
- `ServiceRequestDraft#confirm!` — **the only path that creates a `ServiceRequest`.** In one
  transaction: flips the draft to `confirmed`, builds the request (room and hotel from the
  conversation's session, never from anything the model said), computes `dedupe_key`, and returns
  it. Raises if the draft is not `awaiting_confirmation`.
- `ServiceRequest.dedupe_key_for(conversation:, category:, details:, requested_for_at:)` — SHA-256 of
  the normalized parts.
- `ServiceRequest#transition!(to:, by:, note: nil)` — validates the transition, writes the
  `RequestEvent`, sets the timestamps, and broadcasts. The only way status changes.

- [ ] **Step 1: Write the failing tests for the guarantee**

The tests that matter most in this slice:

```ruby
test "a second live draft for the same conversation is impossible" do
  # create one gathering draft, then assert the DB rejects a second
  assert_raises(ActiveRecord::RecordNotUnique) { ... }
end

test "confirm! creates exactly one request even if called twice" do
  # the second call must raise rather than create a second request
end

test "two identical confirmed requests collapse to one via dedupe_key" do
  # same conversation, category, details, time -> the unique index rejects the duplicate
end

test "confirm! refuses a draft that is still gathering" # no confirmation, no request

test "an expired draft never becomes a request" do
  # travel past expires_at, run ExpireDraftsJob, assert confirm! raises
end

test "the room comes from the guest session, not from the details hash" do
  # pass a foreign room_id in details and assert it is ignored
end
```
That last one is the injection test for this slice: a model persuaded to emit another room's number
must not be able to route a request there.

- [ ] **Step 2: Implement, then verify each guarantee by breaking it**

Remove the partial index and watch the concurrency test fail; remove the `dedupe_key` index and watch
the duplicate test fail. A guarantee whose test you haven't seen fail isn't one.

- [ ] **Step 3: `ExpireDraftsJob`**

Recurring every 5 minutes: drafts older than `expires_at` (30 minutes) move to `expired`. A guest who
abandons a half-finished request mid-conversation must not have it spring to life an hour later.

- [ ] **Step 4: Full suite, commit**

---

### Task 2: The assistant's side — propose, ask, confirm

**Files:**
- Modify: `app/services/ai/tools.rb`, `app/services/ai/prompt_builder.rb`, `app/services/ai/concierge.rb`
- Create: `app/views/guest/chats/_draft_card.html.erb`
- Create: `test/services/ai/service_request_flow_test.rb`
- Modify: `test/services/ai/injection_corpus_test.rb`

**The two tools:**
- `propose_service_request(category_key, details, requested_for?, clarifying_question?)` — creates or
  updates the conversation's live draft. The server validates `category_key` against **this hotel's**
  active categories (an unknown key is an error returned to the model, not a new category), coerces
  `details` to the category's `detail_fields`, and drops anything else. If the draft isn't `ready?`,
  it stays `gathering` and the assistant asks for `missing_fields.first` — one question at a time,
  because a guest on a phone will not answer three.
- `confirm_service_request(draft_id)` — only valid when the draft is `awaiting_confirmation`; calls
  `confirm!`; returns a receipt the assistant relays in the guest's language, with wording that says
  the request has been **sent to reception and is pending**, never that it is confirmed or booked.

**The confirmation card.** When a draft becomes `awaiting_confirmation`, the guest sees a summary
card rendered as a Turbo frame — category, details, time, room — with Confirm, Change and Cancel.
A plain typed "yes" (or "da", "ja", "نعم") must work too: the live draft is injected into the next
prompt as `<pending_draft>`, so the model can call `confirm_service_request` from a bare
affirmative. Both paths converge on `confirm!`, so neither can create two requests.

**Prompt rules to add:** never state or imply that a request is confirmed, approved, booked or
guaranteed before `confirm_service_request` has returned; after it returns, say it has been sent to
reception and is pending. Reservation requests (restaurant, spa) are **requests**, and the wording
must not promise a table or a slot.

- [ ] **Step 1: Write the flow test with `FakeClaude`**

Script the full multi-turn shape and assert on the database, not on the transcript: "two towels" →
`propose` (gathering, one clarifying question asked) → "6pm" → `propose` (awaiting_confirmation, card
rendered) → "yes" → `confirm` → **exactly one** `ServiceRequest` with the right category, quantity,
time and room. Then a variant where the guest says "no" and asserts nothing was created. Then a
variant where the model calls `confirm_service_request` twice and assert still exactly one.

- [ ] **Step 2: Implement, run the injection corpus, commit**

Add to the corpus: a guest message that tries to get a request created without confirmation, and one
that names another room.

---

### Task 3: The reception board

**Files:**
- Create: `app/controllers/staff/service_requests_controller.rb`, `app/controllers/staff/request_events_controller.rb`
- Create: `app/views/staff/service_requests/{index,show}.html.erb` and partials
- Create: `app/policies/service_request_policy.rb`
- Create: `test/controllers/staff/service_requests_controller_test.rb`
- Create: `test/system/request_board_test.rb`
- Modify: `app/views/layouts/staff.html.erb`, `config/routes.rb`, `test/tenancy/cross_tenant_access_test.rb`

- [ ] **Step 1: Failing controller tests**

Filters (status, category, department, room, assignee, date, channel), search (guest name, room,
content), the transitions and who may make them, internal notes never appearing in any guest-facing
response, and the isolation case: hotel A's staff get 404 on hotel B's request.

- [ ] **Step 2: The board**

Optimized for someone standing at a desk with a queue of guests. New requests first and unmissable —
colour, count, and a sound on arrival. Overdue when older than `hotel.overdue_after_minutes` and
still `new` or `accepted`. Each card: room (with the UNVERIFIED badge), category, the guest's own
words, time requested, assignee. One tap to accept, one to complete.

Live updates broadcast to `[hotel, :requests]` with the same resilience layer the inbox uses.

- [ ] **Step 3: Guest-visible status updates**

A `status_change` event posts a `system` message into the guest's conversation in the guest's
language, from **pre-translated strings** (Slice 5 handles anything freeform). "Reception is on it"
for accepted, "on the way" for in progress, "done" for completed, and for declined a plain,
non-technical sentence that does not blame the guest. Nothing here may say a pending thing was
confirmed.

- [ ] **Step 4: System test — the acceptance scenario end to end**

Guest confirms a request; it appears on the board; a receptionist accepts, assigns and completes it;
the guest sees each change. Keep it inside the interaction budget the system-test harness reliably
survives (see the house rules in `slice-1-tasks.md`) — set up the request directly and drive only the
board and the guest's view through the browser.

- [ ] **Step 5: Full suite, commit**
