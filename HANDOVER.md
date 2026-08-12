# Handover

**Written for whoever picks this up next — human or agent, on any machine.**
Read [CLAUDE.md](CLAUDE.md) first if you haven't.

> **Keep this file true.** Update it in the *same commit* as the work it describes. A session can be
> cut off at any moment, and a stale handover is worse than none because the next agent trusts it.

---

## Status at a glance

| | |
|---|---|
| **Last updated** | 2026-08-12 (Slice 7 Task 3 — retention and the right to be forgotten) |
| **Branch** | `main` |
| **Deployed** | Render (Frankfurt, free tier) — `/up` returns 200 |
| **Tests** | 1200 unit/integration green · 41 system green (run four times this session, no flake) · rubocop and brakeman clean |
| **CI** | **Green through `39447e6`** — checked, not assumed. Nothing since has been *observed* on CI by this session; every step was run locally instead (full suite, system suite, rubocop, brakeman). **`bin/rails test:system` locally needs a chromedriver matching the container's Chrome** — see "What will bite you". |
| **Progress** | **Slices 1–6 complete** · Slice 7 Tasks 1–3 of 5 done |

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

**Slice 4 Task 1 — the draft state machine.** Complete. Nothing user-visible yet: this is the
machinery the rest of the slice hangs off, and it is where the product's central promise — *the
assistant may gather and propose, but only a human may confirm* — is made structural rather than
prompted.

- `ServiceRequestDraft` holds a request across the turns it takes to describe one ("two towels" →
  "when?" → "6pm"), knows what is still `missing_fields`, and expires. `#confirm!` is the **only**
  path in the application that creates a `ServiceRequest`, and it refuses anything that is not
  `awaiting_confirmation` and unexpired — a draft still gathering has never been summarised to
  anyone, so confirming it would be the software deciding on the guest's behalf.
- The room, guest session and hotel come from the *conversation*, never from `details`. A model
  persuaded to name another room has nowhere to put it; there is a test that passes a foreign
  `room_id` and asserts it is ignored.
- Two guarantees are Postgres's, not the application's: a partial unique index gives **one live
  draft per conversation**, and `dedupe_key` (SHA-256 of conversation + category + sorted details +
  time) gives **one request per confirmed draft**. Both were verified by dropping the index and
  watching the test go red.
- `ServiceRequest#transition!` is the only way a status changes; every change writes a
  `RequestEvent` naming who made it, and an impossible transition raises rather than being dropped
  onto a board somebody is reading. `#overdue?` reads the hotel's own `overdue_after_minutes`.
- `ServiceRequests::ExpireDraftsJob` (every 5 minutes, in `config/recurring.yml`) closes abandoned
  drafts, which also frees the one-live-draft slot so the guest's next request is not blocked by
  the one they walked away from.

**Slice 4 Task 2 — the assistant's side, and the guest's.** Complete. The multi-turn shape works end
to end against `FakeClaude`: "two extra towels" → one question → "bath towels" → a summary → "yes" →
**exactly one** request. A guest who taps Confirm on the card instead gets the same one.

- `propose_service_request` and `confirm_service_request` in `Ai::Tools`. Propose validates
  `category_key` against **this hotel's active** categories (an unknown key is an error returned to
  the model, never a new category), keeps only the details that category actually asks for, and
  merges onto what is already there so a guest answering "6pm" adds rather than replaces. Confirm
  refuses a draft the guest has not been shown, and refuses a `draft_id` that is not this
  conversation's live draft.
- The prompt gained `<request_categories>` in the cached block (the only vocabulary propose accepts,
  re-checked server-side regardless) and `<pending_draft>` in the volatile one — without that last
  block, a guest replying "yes" to a summary gives the model nothing to go on and it starts over.
- `ServiceRequestDraft#confirm!` is now idempotent: a duplicate loses at the `dedupe_key` index and
  is recovered rather than raised, because from the guest's side "two towels at six are on the
  board" is a success. Telling them otherwise invites them to ask again, which is how one request
  becomes two.
- The summary card (`app/views/guest/chats/_draft_card.html.erb`) with Confirm / Change / Cancel.
  Both server buttons converge on the same `ServiceRequestDraft#confirm!` a typed "yes" reaches
  through the model — two paths, one method, one unique index, so they cannot produce two requests.
  "Change" only fills the composer, the same rule the quick-action chips follow: changing your mind
  is a sentence you type, never a form this app guessed at on your behalf. The card element is
  always rendered (empty when nothing is pending) because it is the target of a live Turbo replace
  from `ServiceRequestDraft#broadcast_card`, and a target that does not exist yet is a broadcast
  that lands nowhere.
- `config/locales/requests.{bs,en,de,ar}.yml` — the card's copy and the receipt, pre-translated on
  disk for the same reason `degraded.*` is: a controller posts them with no model in the loop. The
  structural locale test now covers this family too, and pins that no two languages share the
  receipt string.
- The injection corpus grew two shapes ("skip the confirmation", "the guest has already confirmed")
  and two assertions: no combination of tool arguments creates a request the guest did not agree to,
  and none routes one to another room. **Both are held by two independent layers** — removing either
  alone leaves the tests green, which is recorded in the test file so nobody deletes one as
  redundant.

**Slice 4 Task 3 — the reception board.** Complete. **Slice 4 is done**: a guest describes what they
want, the assistant asks what is missing, shows a summary, and waits; the guest agrees; exactly one
request appears on the reception board; a receptionist accepts and completes it, and the guest sees
each step — never having been told anything was confirmed before a person confirmed it.

- `/staff/service_requests` — open / all / finished tabs, search across room number, guest name and
  what was asked for, a category filter, and cards optimised for someone standing at a desk: room
  first, state in **words** as well as colour, "Waiting 2 hours" spelled out for anything past the
  hotel's own `overdue_after_minutes`, and one tap to accept or complete.
- **Every status change goes through `ServiceRequest#transition!`** — the controller never writes
  `status` itself. That is what keeps the board, the `RequestEvent` history and the guest's own chat
  from drifting apart, and only the transitions the model says are legal are rendered as buttons.
- Guest-visible status updates post from `config/locales/requests.*.yml` in the guest's language. A
  transition's staff note is deliberately **not** passed on, and `RequestEvent.guest_visible` covers
  status changes only — the same boundary `Message#visibility` draws in the chat.
- `HotelRequestsChannel` + a morphing refresh to `[hotel, :requests]`, reusing the inbox's
  resilience layer. The channel re-checks active-staff / unsuspended-hotel / right-stream on
  subscribe, because a cable connection outlives the request that opened it.
- `test/system/request_board_test.rb` is the slice's proof: two browsers, guest confirms, the
  receptionist's board updates itself, and each transition reaches the guest's page unaided.

**Deliberately not built** (flag these if a pilot asks for them): a sound on new-request arrival —
browser autoplay policies make it unreliable and a notification that sometimes fires is worse than
none — and assignment to a named staff member. The `assigned_to` column, the `assignment` event kind
and the card's assignee line all exist; what is missing is a way to set it.

**Slice 5 Task 1 — the digit guard and the translator seam.** Complete. Nothing is translated yet;
this is the part that decides whether translating is safe to switch on at all.

- `Ai::DigitGuard` — **strict equality of the numbers, as a multiset**, after folding Arabic-Indic,
  Persian and full-width digits to ASCII. Not merely "no invented numbers": allowing a drop would
  let a translation turn "is breakfast at 07:00 or 08:00" into a question a receptionist cannot
  answer. Formatting differences are not differences (`07:00` vs `7:00`, `12.5` vs `12,5`), because
  a guard that fires on correct translations is a guard that gets switched off.
- The strictness has a cost, stated and tested: a translation that spells a number as a word falls
  back. Readability suffers, correctness does not. If a pilot shows it firing often, **fix the
  translator's prompt, not the guard.**
- `Ai::Translator` + `Ai::Translation` — one call on `TRANSLATION_MODEL`, and it **never raises**.
  Timeout, API error, refusal, truncation, empty reply and digit mismatch all return the original
  text marked with a `reason`. It sits on the guest-to-receptionist lifeline; it is allowed to fail
  and not allowed to break that path. Same language on both sides costs nothing at all — no call, no
  tokens.

**Slice 5 Task 2 — the translation claim and the budget.** Complete. Messages are now translated in
the background for whoever has to read them; nothing renders the result yet (that is Task 3).

- **The delivery question is decided**, and the decision is written up in
  `docs/plan/known-issues.md` along with the case for the other choice and how to reverse it. On the
  web a message broadcasts the instant it is written and the translation arrives afterwards as an
  overlay. Holding it would have traded a real failure — an inbox showing nothing for fifteen
  seconds after a guest hit send — for a cosmetic one.
- The claim therefore guards *translation* rather than delivery:
  `Message#claim_translation!` moves `pending → translating` in one atomic statement, so a duplicate
  enqueue, a retry, or the watchdog racing the job can never make a hotel pay twice.
  `messages.delivered_at` is still unused and belongs to Slice 6.
- `Ai::TranslationWatchdogJob` (every minute) settles translations that never came back, so nobody
  is left staring at "translating…". The 15-second budget is pinned by its own test — every other
  test is relative to the constant and would stay green if someone widened it to an hour.
- `Message#translation_target_locale` is the single answer to "which direction, and into what": a
  guest message goes into the hotel's staff language, a staff reply into the guest's, and system
  notices and assistant replies are skipped (both are already in the right language). The fixtures
  give both hotels `bs` for staff and guest, so **any test about direction must set one of them
  explicitly** or it passes whichever way round the code has it — that caught a real swapped-
  direction break.

**Slice 5 Task 3 — both directions on screen.** Complete. A guest and a receptionist who share no
language can now hold a conversation, each reading their own, with the other's actual words one tap
away.

- One partial, `app/views/shared/_translated_body.html.erb`, used by both surfaces. Both texts are
  in the DOM with one hidden, so the original is findable by selection, by a screen reader, and with
  JavaScript off.
- **The bug the tests caught, and the rule that fixes it:** a reader is never shown their own words
  translated back at them. The staff-facing translation of a guest's message is in the language the
  guest's own interface renders in whenever the locales line up that way, so the first version
  showed a German-speaking guest the Bosnian translation of their own question. The partial takes a
  `translate` local and the caller decides — guest surface translates what the guest did not write,
  staff surface what staff did not write.
- Assistant replies are translated lazily, from `Staff::ConversationsController#show`. The concierge
  already answered in the guest's language; the staff-facing copy is worth paying for exactly when
  someone is reading it.
- **Writing tests here:** the guest's *session* locale renders their surface, the *conversation's*
  is what the translator aims at. Set only one and the test reads as though it passed —
  `#speaking_german` in `test/controllers/translation_rendering_test.rb` sets both.

**Slice 5 Task 4 — the staff workspace in Bosnian, and the request-summary overlay.** Complete.
**Slice 5 is done**: an Arabic-speaking guest and a Bosnian-speaking receptionist hold a conversation
each reading their own language; a request the guest confirmed in Arabic shows the receptionist a
summary in *their* language with the guest's own words one tap away; and the staff workspace itself
now speaks Bosnian, per user, not per hotel. Landed as two commits, exactly as briefed.

*Piece 1 — the staff workspace in Bosnian* (commit `e31fa04`):

- Every hardcoded English string across the 28 templates in `app/views/staff/**`, the staff layout,
  and `StaffHelper` moved into `config/locales/staff.{bs,en}.yml`. Purely mechanical — no behavioural
  change beyond the locale switch itself.
- `StaffLocalization` (new controller concern, mirroring `GuestLocalization`), included in
  `Staff::BaseController`: `I18n.locale` for a staff request follows **`Current.user.locale`**, never
  `Hotel#staff_locale` — a different axis entirely, the translation target for guest↔staff overlays,
  one fixed language per hotel. A Bosnian receptionist and an English-speaking manager now correctly
  see their own language at the same hotel. `User#locale` gets the same `inclusion` validation
  `Hotel#staff_locale` already had, against the same `Hotel::STAFF_LOCALES`.
- **A real bug found and fixed along the way:** the nav badge's DOM id was derived from the
  (now-translated) label text via `.parameterize`, so `#knowledge-gaps-badge` silently became
  `#praznine-u-znanju-badge` the moment the label was Bosnian. Nav items now carry a stable,
  locale-independent `:id` (`app/helpers/staff_helper.rb#staff_nav_items`).
- `test/i18n/guest_locale_files_test.rb` renamed to `locale_files_test.rb` and reworked from one
  shared `LOCALES` constant to a per-family `FAMILY_LOCALES` hash — staff speaks `bs`/`en`, the
  guest-facing families speak `bs`/`en`/`de`/`ar`. Still reads every file straight off disk, not
  through `I18n.t`, for the same fallback-absorption reason the original test existed.
- **The trap the brief called out, made concrete:** every other staff fixture (`stari_admin`/
  `stari_staff` vs `vrelo_admin`/`vrelo_staff`) happens to have its `user.locale` agree with its own
  hotel's `staff_locale` — so keying the render off the hotel instead of the user would have passed
  the *entire* existing suite. `test/controllers/staff/localization_test.rb` deliberately creates a
  user whose locale disagrees with their hotel's, and is the one test that actually catches that
  mistake — verified by temporarily keying `StaffLocalization` off `Current.hotel.staff_locale` and
  watching all three of its tests go red.
- ~20 existing controller/system tests updated: their fixture actors (`locale: bs`) now correctly
  render Bosnian, and rails-i18n turns out to already ship Bosnian translations for the *standard*
  ActiveRecord error vocabulary (`"Name je već zauzet"` for "has already been taken", etc.) — a
  pleasant surprise worth knowing before you go looking for where that came from.
- **Deliberately out of scope, left English:** ActiveRecord *attribute names* inside composed
  validation errors (rails-i18n translates the error text, not the field name — see above), and the
  QR print sheet's guest-facing four-language card content (that page is guest signage that happens
  to render from a staff route, not staff chrome). Controller-generated flash messages were
  *originally* left out of scope here too — see Piece 3 below for why that changed.

*Piece 2 — the request summary overlay* (commit `ddc7d45`):

- `service_requests.details_original` (the guest's own words, exactly what `ServiceRequestDraft
  #build_request` shows the guest to confirm) is now actually populated — the brief's premise that it
  already was turned out to be slightly ahead of the code; verified by grep before assuming otherwise.
  `summary` starts out identical to it and stays that way — a receptionist who opens the board before
  translation lands simply reads the original, never wrong, only not yet translated.
- `Ai::TranslateServiceRequestSummaryJob`, the request-summary counterpart of `Ai::TranslateMessageJob`,
  reusing `Ai::Translator` directly (no second translation path, no second digit-guard implementation).
  Enqueued once from `ServiceRequestDraft#confirm!` — **never synchronously in the guest's own
  confirm request/response cycle**, the same reasoning Task 2 already established for messages. On
  success it overwrites `summary` in place with a translation into the hotel's `staff_locale`; on any
  failure (timeout, refusal, or the digit guard itself) `Ai::Translator`'s own fallback already hands
  back the original, so `summary` is simply left untouched.
- No new `translated_summary`/`translation_status` columns: `summary != details_original` **is** the
  "translated successfully" signal, because nothing else is ever allowed to make them differ
  (`ServiceRequest#details_original_is_immutable_after_creation`, same shape as `Message#body`'s own
  guard). `ServiceRequest#readable_in(locale)` and `#summary_translation_target_locale` are the model
  half of the overlay, mirroring `Message#readable_in` / `#translation_target_locale` deliberately.
- `app/views/staff/service_requests/_summary.html.erb` — a new, small overlay partial (not a change to
  the existing `shared/_translated_body.html.erb`, which Task 3 already shipped and tested for
  messages; reusing it would have meant changing its interface and re-risking already-working code for
  a caller with a different, simpler state shape). Reuses the same generic `translation-toggle`
  Stimulus controller as-is. Every element is phrasing content (`span`, never `p`/`div`): it renders
  inside both the board card's `<p>` and the request page's `<h1>`, and only phrasing content nests
  validly inside a heading.
- **The digit guard, proven where it actually matters this time:** a dedicated job test feeds the
  translator a summary that changes "2" to "20" and asserts the board still shows the guest's original
  numbers — then, to make sure that test isn't a decoration, `Ai::DigitGuard.safe?` was temporarily
  hard-coded to `true` and the mangled translation *did* reach `summary`, confirming the test is load-
  bearing rather than accidentally green. Restored immediately after.
- 838 unit/integration + 41 system tests green, rubocop and brakeman clean.

*Piece 3 — the way in, and the flash messages* (this commit): a coordinator review of the first two
pieces found two of the three "deliberately out of scope" calls above drawn in the wrong place. Both
are fixed here, as their own commit, on the same working agreement as the first two (literal strings
in tests, break-and-restore evidence, full suite before committing).

- **`User#locale` was validated and fully wired into rendering, and nothing in the application could
  ever set it.** `Staff::UsersController` permitted `:name, :email_address, :password,
  :password_confirmation` on create and `:active` alone on update — no route, form, or `permit` call
  anywhere touched `locale`. A hotel could turn the whole workspace Bosnian in the fixtures and the
  seed data and still have no way to give a real receptionist that language short of a Rails console
  on the production box. Fixed with two ways in:
  - `Staff::PreferencesController` (new) + `resource :preferences, only: %i[edit update]` (new route,
    singular, no id) — any active staff member's own way to change their own language, gated by
    nothing but `Staff::BaseController`'s existing "signed in and active" check (no Pundit policy: the
    same reasoning `Staff::DashboardController` already needs none for "may I see my own dashboard").
    Linked from the layout header, next to "Signed in as ... / Sign out".
  - `Staff::UsersController#user_params`/`#user_update_params` now also permit `:locale`, and
    `staff/users/new.html.erb` / `edit.html.erb` each carry their own field for it — a hotel_admin
    setting it when creating an account, or changing a colleague's afterwards. The edit form's locale
    field is its **own** `form_with`, separate from the existing activate/deactivate button, the same
    "two forms, not one with a toggle" reasoning `staff/conversations/_composer.html.erb` already
    documents — so a language change can never carry a stray `active` value along with it.
  - The guarantee that matters most — a staff member cannot touch anyone else's account through the
    self-service route — is structural (no id anywhere in `resource :preferences`'s path or params),
    not just a check that could be forgotten on a future action. Proved empirically anyway:
    `test/controllers/staff/preferences_controller_test.rb` signs in as one user, changes their
    language, and asserts a *second* user's row is untouched; a smuggled `user_id`/`id` in the POST
    body is asserted to have no effect. Verified load-bearing by temporarily making the controller
    honor a smuggled `user_id` and watching that exact test go red.
  - The post-change confirmation is built under the **new** locale, not the one the request started
    under (`I18n.with_locale(Current.user.locale) { t(".updated") }` — read only after the update
    already succeeded) — otherwise a user switching Bosnian→English would see one leftover Bosnian
    sentence on the English page the redirect lands them on. Tested in both directions.
  - Rule 8 stays intact: `Hotel::STAFF_LOCALES` is still the only list either path validates against
    or offers in a `<select>` — nothing here widened staff locale to the guest four.
- **~23 controller-generated `notice:`/`alert:` strings across all 10 staff controllers**, moved into
  `config/locales/staff.{bs,en}.yml` the same way the view layer was in Piece 1. Two kept the shape of
  the reasoning already used for view strings: `Staff::MessagesController`'s superseded-conversation
  alert and `Staff::KbEntriesController`'s `gap_notice` (now returns `nil`, not `""`, for "nothing to
  say" — joined in Ruby with `Array#compact_blank`, not baked into the YAML as a leading-space string,
  which would have risked the structural locale test's blank-value check).
  - **The one with real pluralization** — `Staff::RoomsController#bulk_create`'s "N room(s) added, M
    skipped as duplicate(s)" — was English-only string surgery (`"room#{"s" unless n == 1}"`), which
    only ever produces correct *English* and says nothing about Bosnian's own plural rules. Rebuilt on
    Rails' own `t(key, count:)`, as two independently-pluralized phrases (`created_phrase`,
    `skipped_phrase`) wired together, because one `count:` can't drive two different numbers in the
    same sentence. Verified load-bearing by reverting to the old string-surgery version and watching
    both the original test and a new complementary one (created: 1/skipped: 2, the inverse count
    combination) go red.
  - **Bosnian pluralization: since fixed properly** (commit `bafbe63`). This bullet used to record
    a two-form `one`/`other` approximation as a deliberate limit. It was not a limit worth keeping —
    Bosnian's middle form covers counts of 2–4, which is the range a receptionist actually hits, so
    "2 soba dodano" was simply wrong where the language wants "2 sobe dodane". The correct rule
    already shipped with `rails-i18n` and was sitting inert; `config/initializers/pluralization.rb`
    includes `I18n::Backend::Pluralization` so the backend can consult it. Two measurements changed
    the plan on the way: Bosnian's effective CLDR rule asks for `one/few/other`, **not** the
    `one/few/many/other` of the East Slavic file (a `many` key is never read), and a key missing
    `few` does **not** raise at count 2 — I18n silently falls back to `other`. That silence is why
    `test/i18n/locale_files_test.rb` now checks every pluralised key against its own locale's
    declared forms.
  - **Still deliberately English, and said so in the code** (`Staff::RoomsController#bulk_create`'s
    `Room::BulkRangeTooLarge` rescue, `Staff::ServiceRequestsController#transition`'s
    `ServiceRequest::InvalidTransition` rescue): both relay a raw Ruby exception message from a model,
    not a routine confirmation — a defensive guard against an absurd bulk paste, and a race between two
    staff members on the same request in two tabs. Translating these means the model deciding what
    language to speak, or the controller mapping exception classes to i18n keys — a real, separate
    design question, not a mechanical string move, and out of scope for a same-day fix round.
  - ActiveRecord's own `.errors.full_messages.to_sentence` relays (four of them, unchanged) continue to
    read partially in Bosnian via rails-i18n's own vocabulary, same as Piece 1.
- A transient system-test run mid-session errored on all 41 tests at once with `Errno::ECONNREFUSED`
  connecting to chromedriver — diagnosed before treating it as a regression (no chromedriver process
  was actually holding the port; ~111 already-open Chrome tabs were the likely resource contention). An
  immediate clean re-run passed all 41 with no changes. Recorded per the "diagnose, don't guess"
  house rule, not silently reran-until-green.
- 850 unit/integration + 41 system tests green, rubocop and brakeman clean.

**Slice 6 Task 1 — the channel, the port, and one provider behind it.** Complete. The foundation the
rest of the slice stands on. Nothing downstream changed: `Ai::Concierge`, `Conversation` and every
staff view are untouched — the seam is entirely new files plus one `has_one` on `Hotel`.

- `WhatsappChannel` — `has_one` on `Hotel`, `TenantScoped` like every other hotel-owned resource (not
  a judgement call: `test/tenancy/tenant_declaration_test.rb` auto-scans every `ApplicationRecord`
  with a `hotel_id` column and fails the suite if it isn't). `phone_number_id` — Meta's own routing
  id, not the displayed number — is **globally** unique, not merely unique per hotel: a plain
  (non-partial) index at the database level, proven by a test that switches Rails validation off
  entirely (`collider.save!(validate: false)`) so only Postgres is left standing between two hotels
  sharing an id. `phone_number_e164` and `hotel_id` (one channel per hotel) get the same two-layer
  treatment (validation + index), each verified by dropping the index / removing the validation and
  watching the specific test go red. `phonelib` (declared in the Gemfile ahead of this slice,
  genuinely unused anywhere until now) validates the number is real, not a hand-rolled regex.
- `Whatsapp::Provider` — the port — plus `Whatsapp::MetaCloudProvider`, the one adapter this slice
  ships. `.for(channel)` dispatches on `channel.provider`; `three_sixty_dialog`/`twilio` raise a
  clear `ArgumentError` rather than silently guessing, since only Meta Cloud is actually implemented.
  `#send_text`/`#send_template` build Meta Cloud API's documented JSON shape over `Net::HTTP` (stdlib
  — no new gem needed for one POST endpoint); every test asserts the exact URL, the
  `Authorization: Bearer` header and the exact JSON body against WebMock, never a mock of the
  provider standing in for itself (rule 1 — verified load-bearing by injecting an extra undocumented
  key into the request body and watching the shape assertion catch it).
- **The 24-hour customer service window lives in the provider, not the caller**: `#send_text` raises
  `Whatsapp::WindowClosedError` when `Time.current > conversation.last_guest_message_at + 24.hours`.
  `conversation:` is duck-typed on `#last_guest_message_at` alone, so the boundary tests need no
  Hotel/GuestSession/Conversation graph at all — a plain `Struct` is the real collaborator, not a
  stand-in for one, and the whole file needs no `ActsAsTenant.with_tenant` anywhere. `#send_template`
  is deliberately exempt — a pre-approved template is exactly Meta's own escape hatch from the
  window. **A real bug caught along the way**: the first version of the "exact boundary moment" test
  passed under both the correct `>` and a deliberately-reintroduced wrong `>=`, because Rails'
  `travel_to` defaults to `with_usec: false` and silently truncates to whole seconds — up to ~999ms
  of slack that hid the very off-by-one the test existed to catch. Fixed with `with_usec: true`;
  re-verified load-bearing by reintroducing the `>=` bug afterward and watching the corrected test
  (and only that test) go red.
- Typed errors mirror `Ai::`'s own hierarchy exactly: `Whatsapp::Error` (base), `AuthenticationError`
  (401 — someone must fix the configured token), `RateLimitedError` (429, carries Meta's own
  `retry-after` when it sends one), `ApiError` (everything else, carries `status`),
  `WindowClosedError`. Each mapping verified by temporarily collapsing it into the generic case and
  watching the specific test (and only that test) go red.
- `Whatsapp::InboundMessage` / `Whatsapp::DeliveryStatus` — the normalized structs Slice 6 Task 3's
  inbound router will populate from a real webhook payload. Deliberately inert in this task (no
  parser yet, by design — Task 1's own checklist never asks for one): nothing here constructs one
  yet, so a dedicated test would only exercise `attr_reader`.
- `config/initializers/whatsapp.rb` mirrors `config/initializers/ai.rb` exactly: one
  `WHATSAPP_ACCESS_TOKEN` for the whole app, not per hotel (Hospello is the Meta Tech Provider, and
  this system-user token can send on behalf of every hotel's `phone_number_id` it has been granted —
  see `docs/whatsapp-onboarding.md`; `whatsapp_channels` has no `access_token` column of its own for
  exactly that reason), plus `WHATSAPP_API_VERSION` (default `v22.0`). Both documented in
  `.env.example` and `README.md`'s env var table. Neither is required for the app to boot or for any
  hotel's QR web chat to keep working.
- **Deliberately not wired into `render.yaml` yet**: nothing reads these in production today — no
  webhook (Task 2), no send call (Task 4), no UI to create a `WhatsappChannel` row (Task 4) — so
  there is nothing yet for a missing secret to break. Add `WHATSAPP_ACCESS_TOKEN` /
  `WHATSAPP_API_VERSION` to `render.yaml` whenever a task actually makes an outbound send live, most
  likely Task 4.
- A transient `bin/rails test:system` run mid-session errored on 38 of 41 tests at once, with a
  signature (screenshot-capture itself failing inside `ActionDispatch::SystemTesting`) consistent
  with the Chrome/chromedriver resource-contention flake this file's Slice 5 Task 4 section above
  already documents (~111 open Chrome-related processes measured then; 116 measured this session).
  Diagnosed rather than assumed: nothing changed between that run and the clean ones immediately
  before and after it touched any system-tested surface at all (WhatsApp has no UI yet), and two
  immediate re-runs both passed 41/41 with no changes made. Recorded per the same "diagnose, don't
  guess" house rule, not silently reran-until-green.
- 888 unit/integration (852 + 36 new: 13 model, 23 provider) + 41 system tests green, rubocop and
  brakeman clean.

**Slice 6 Task 2 — the webhook: fast, idempotent, and impossible to forge.** Complete.
`POST /webhooks/whatsapp` is now live and is the only unauthenticated, publicly reachable endpoint in
this app that accepts a body — every guarantee below was proven by breaking the code and watching the
specific test (and only that test) go red, not by inspection.

- `Webhooks::WhatsappController` deliberately does **not** inherit `ApplicationController` — it
  inherits `ActionController::Base` directly. `ApplicationController` bundles three things that make
  no sense for a server-to-server callback: `Authentication`'s `before_action` (would redirect every
  delivery to a sign-in page Meta can't follow), `Pundit` (nothing here is authorized against a user —
  there is no user), and `allow_browser versions: :modern` (a "is this a recent Safari/Chrome/Firefox"
  User-Agent gate with no defensible answer for a webhook, and not something this endpoint's
  availability should depend on). CSRF protection is still on by default at the
  `ActionController::Base` level regardless of ancestry, so it's skipped explicitly
  (`skip_before_action :verify_authenticity_token`) — proven load-bearing by temporarily re-enabling
  `ActionController::Base.allow_forgery_protection` (off app-wide in test) for one request and
  watching it 422 without the skip.
- **Forgery**: `Whatsapp::WebhookSignature.valid?` — HMAC-SHA256 over `request.raw_post` (never
  `params`, which Rails has already parsed/reordered by the time a controller sees it — signing that
  would verify something the sender never sent), compared with
  `ActiveSupport::SecurityUtils.secure_compare`. One implementation, called from both the controller
  (the real gate) and the rack-attack safelist (below) — proven called, not just present, by
  monkey-patching `secure_compare` and asserting it actually ran. Deleting the verification call
  entirely made 7 of 9 signature tests go red (the 2 that stayed green were the two *legitimate*-
  signature tests, correctly — a stub `return true` still accepts those).
- **Replay**: `webhook_events` — this app's **one** deliberately non-tenant-scoped table (say so
  everywhere: model, migration, and `TenantDeclarationTest::EXEMPT`, or the next reader assumes it was
  missed). `[provider, external_id]` has a real unique index; the controller writes through it with
  `insert_all(..., unique_by:)` — `ON CONFLICT DO NOTHING` — proven database-level (not merely
  Rails-level) by dropping the index directly against the test DB and watching exactly the DB-level
  test fail while the validation-level test stayed green. A replay still resolves the row's id and
  still enqueues a job even when its own insert lost the conflict (a plain indexed lookup on the
  miss) — a deliberate choice beyond the brief's literal wording: if a process died between a first
  delivery's insert and its enqueue, a Meta retry is the only thing that can recover it, so "replay is
  harmless" has to mean *recoverable*, not merely deduplicated at the row level.
- **Speed**: insert, enqueue `Whatsapp::ProcessInboundJob` on the **`critical`** queue, return 200 —
  never inline processing, never behind the `ai` queue. `Whatsapp::ProcessInboundJob` itself is a
  deliberate, documented no-op stub in *this* task (`TenantFree`, since no hotel is known yet) —
  Slice 6 Task 3 gives it a real body; Task 2 only had to guarantee the class exists and is safe to
  enqueue, since the controller's own step 2 requires enqueuing it now.
- **Never raises on a malformed body**: a signature-verified-but-non-JSON payload (can't happen from
  real Meta, defensive only) is caught, reported to Sentry, answered 200 — proven by deleting the
  rescue and watching the exact `JSON::ParserError` propagate unhandled.
- **The GET handshake** (`hub.mode`/`hub.verify_token`/`hub.challenge`) echoes the challenge only on a
  matching token, compared with `secure_compare` too — not strictly required by the brief's own
  constant-time language, but there's no reason to hold it to a lower standard than its neighbor for a
  few characters. Two new secrets, neither the existing `WHATSAPP_ACCESS_TOKEN`: `WHATSAPP_APP_SECRET`
  (the Meta *App* Secret, a different credential from a different dashboard page — signs the delivery)
  and `WHATSAPP_WEBHOOK_VERIFY_TOKEN` (a value this app makes up for the one-time handshake). Both
  **fail closed** when unset — refuse everything, never trust by default — documented in
  `.env.example`, `README.md`, and `config/initializers/whatsapp.rb`.
- **Rack::Attack**: the reserved, commented-out safelist is now real, gated on
  `Rack::Attack.verified_whatsapp_signature?(req)` — a *class* method, not inlined in the block, since
  Rack::Attack calls safelist blocks with `block.call(req)`, never `instance_exec`'d, so `self` inside
  the block is whatever it was at the block's own definition site (the `Rack::Attack` class body
  itself). That method reads the raw Rack body (`req.body.read`) and **must** `.rewind` it afterward —
  plain `Rack::Request#body` returns the live, shared `rack.input` with none of
  `ActionDispatch::Request#raw_post`'s own caching, so a missing rewind would silently hand the
  controller an empty body for every real delivery this safelist inspects. Proven two ways: deleting
  the rewind made the two body-content tests (which read `req.body` a second time, directly — not
  through a full Rails request, which independently re-rewinds and would have hidden the bug) go red
  with `""` where the real body belonged; deleting the safelist itself made a request that had already
  exhausted a (test-only, temporarily-registered) matching throttle come back 429 instead of success —
  necessary because *no throttle in this file actually matches `/webhooks/whatsapp` today*, so a test
  against the real throttle set would have passed with or without the safelist.
- 930 unit/integration (888 + 42 new: 9 model, 9 signature service, 3 job stub, 17 controller, 4
  rack-attack) + 41 system tests green (run twice, both clean — no flake observed this session),
  rubocop and brakeman clean. Brakeman's `SkipBeforeFilter` check, specifically relevant to this
  task's CSRF skip, raised nothing; its only warning is the pre-existing, unrelated Rails-EOL notice.

**Slice 6 Task 3 — inbound processing: routing, identity, the room question, delivery statuses.**
Complete. A stranger messages a hotel's WhatsApp number, is asked for their room and name before
anything else, answers, and from that point on is an ordinary guest: same reception inbox, same
concierge, same grounding, same confirm-before-create request flow, same request board.
`test/services/whatsapp/inbound_flow_test.rb` drives exactly that, from a real webhook payload to a
`ServiceRequest`, and is the file to read first.

- `Whatsapp::MetaCloudProvider.parse_webhook` — the adapter's inbound half, and still the only file
  in the app that knows Meta's wire format. It returns `Whatsapp::InboundBatch`es: **one per
  (entry, change)**, because Meta's envelope is plural at both levels and different entries can
  carry different `phone_number_id`s — which in this app means *different hotels*. Reading only the
  first of each (the obvious implementation, and what the webhook controller's own dedupe key does
  deliberately) would silently drop another hotel's guest. Chosen by
  `Whatsapp::Provider.parser_for(webhook_event.provider)`, not by a channel: parsing happens before
  any channel is known, because the payload is what finds one.
- `WhatsappChannel.route(phone_number_id)` — the one query in this app that must find a row *before*
  a tenant exists, since the row is what picks the tenant. Same mechanism and same reasoning as
  `GuestSession.authenticate_by_token` (`find_by_sql` never touches acts_as_tenant's default_scope,
  so it needs no escape hatch and sets none), and safe for one reason of its own: `phone_number_id`
  is globally unique, so there is exactly one row it can return. **Named individually in
  `test/tenancy/without_tenant_grep_test.rb`'s ALLOWLIST** — whose second test is now a loop over
  every entry rather than one hand-copied guard per file.
- `Whatsapp::InboundRouter` — routes, then runs everything else inside
  `ActsAsTenant.with_tenant(hotel)`. **Nothing escapes `#route!`**: an unknown `phone_number_id`
  marks the event `ignored` and reports a (never-raised) `Whatsapp::UnroutableDelivery` to Sentry, and
  a genuine crash marks it `failed` with the message. Meta was answered 200 long before any of this
  runs, so a raise here could only fill the failed-jobs table with something a human has to read out
  of a stack trace instead of out of a `webhook_events` row.
- Refused, each with its own test: a **suspended hotel** (WhatsApp is not the one door left open) and
  a **disabled channel**. Deliberately *not* refused: a **pending** channel — a channel is pending
  from registration until someone confirms it works, and the message that confirms it works arrives
  on it.
- `GuestSession.for_whatsapp` — identity is the phone number and nothing else, race-safe against the
  partial unique index that already existed. Always `unverified`, always **roomless**, no
  `token_digest` (there is no cookie on this channel). `privacy_accepted_at` is stamped from the
  guest's **own message timestamp**: there is no checkbox and there cannot be one, so writing to a
  number the hotel published is the consent event. `guest_name` starts as the WhatsApp profile name,
  falling back to the phone number — language-neutral and immediately recognisable to a
  receptionist, unlike an invented English placeholder on a Bosnian workspace.
- **An expired WhatsApp session is renewed, not refused** (`#renew_for_whatsapp!`). The web's answer
  to expiry is the entry form; there is no form here, and the phone number's own unique index
  forbids a second row. Renewing **clears the room**, because an expired session means a new stay and
  the previous room is now a guess about somebody else's.
- `Conversation` derives `channel` from the guest session on create — **assigned outright, not
  `||=`** like its three sibling callbacks, and the difference is load-bearing: `channel` has a
  database default of `web`, so `||=` would silently never fire and every WhatsApp guest would sit on
  a `web` conversation until Task 4's outbound send quietly did nothing.
- `Conversation#post_guest_message!` gained `external_id:`. The two dedupe anchors are looked up
  differently on purpose: `client_message_id` is unique **per conversation** (the browser's uuid), so
  it is looked up through this conversation's messages; `external_id` is unique **globally** (Meta's
  own id), so it is looked up across the hotel — a Meta retry arriving after a receptionist resolved
  the conversation lands on a *new* live conversation, and a lookup scoped to the old one would miss,
  insert, and hit the index with nothing left to recover.
- `Message#apply_delivery_status!` — `delivered_at` finally means something. Out-of-order callbacks
  are ordinary on WhatsApp, so a callback applies only when it moves the message **forward** along
  `DELIVERY_PROGRESS`. `failed` sits at the top deliberately ("once failed, stays failed"): it is the
  one outcome a receptionist has to act on, and the alternative lets a stray late callback hide a
  message that never arrived. `read` fills in `delivered_at` too — a read message was self-evidently
  delivered, and a nil there would read as "never delivered".
- **Deliberately not handled: non-text inbound messages** (images, locations, voice notes). Parsed,
  logged, and settled as `ignored` — not written into the transcript with an invented placeholder
  body, because what a receptionist should see for "the guest sent a photo" is a copy decision with
  four locales behind it. Recorded in `docs/plan/known-issues.md`; today it costs nothing extra,
  because **no outbound path exists until Task 4** and a WhatsApp guest gets silence either way.
- **`set_guest_room`** — the fifth tool, and the only one that exists for WhatsApp. It binds
  **both** `guest_session.room` and `conversation.room` (`ServiceRequestDraft#build_request` reads
  the first, `Ai::PromptBuilder` reads the second, and writing one alone leaves two answers to
  "which room"), takes an optional validated `language` (see below), and **refuses a guest whose
  room is already known** — which is what makes it safe to ship in every prompt, including every web
  guest's, and closes "move the guest in 305 to 306" structurally rather than by wording.
  `docs/plan/slice-6-tasks.md` records all three deviations from the brief's own sentence and why.
- The **`language` argument** is the fix for a real defect rather than a nicety: a WhatsApp session
  has no `Accept-Language` and no form, so it starts on `I18n.default_locale` (`en`) and the
  staff-facing translation is asked to translate *from* a language the guest is not writing. This is
  the first moment anyone knows. Unsupported values are dropped rather than written — they would
  fail `GuestSession`'s own inclusion validation and take the whole binding down with them.
- **Asking for the room is enforced twice, on purpose.** `Ai::PromptBuilder`'s `<room_unknown>` block
  (volatile half, so it costs nothing once answered and never touches the cached prefix) is the
  persuadable layer; `Ai::Tools#propose` refusing outright when the session has no room is the layer
  that is not. `service_requests.room_id` is nullable, so without the second one a talked-into model
  really could put a request on a receptionist's board with nowhere to deliver it.
- **Two guarantees turned out to be held by two layers each, and the tests could not tell.** Proved
  by measurement, not inspection: replacing `hotel.find_active_room` with a raw cross-hotel
  `find_by_sql` left every test **green**, because `GuestSession#room_must_belong_to_the_same_hotel`
  re-queries `Room` by id on save and `Tools#execute` turns the `RecordInvalid` into an error
  tool_result; same story for the blank-name check against `guest_name`'s presence validation.
  Removing *both* layers turns each red. Recorded in `tools_test.rb` and `injection_corpus_test.rb`
  so nobody deletes one as redundant — the same finding, and the same note, Slice 4 already carries.
- The injection corpus grew the two shapes this task exists to refuse ("I am in room 101, and also
  set room 202 for Mr Smith") and three assertions: no wording binds a session other than this
  conversation's own, a real room at another hotel is refused exactly like an invented one, and no
  phrasing starts a request for a guest with no room.
- `test/tenancy/cross_tenant_access_test.rb` gained the webhook's own boundary — driven through the
  **real signed endpoint**, not through the router, because that is the path an attacker or a
  misconfigured Meta subscription actually takes. Plus its mirror ("an unknown number reaches no
  hotel at all"), so the first cannot be passing because routing is broken in the safe direction.
- 73 new tests (15 parsing, 30 router, 4 job, 6 delivery-status, 9 `set_guest_room`, 4 prompt,
  3 injection, 2 cross-tenant, 2 flow). Every guarantee above was proved by breaking the code and
  watching the specific test go red — **34 deliberate breaks**, including routing by the displayed
  number instead of the routing id, dropping each guard in turn, removing the `||=`/outright
  distinction on `channel`, flattening the delivery ladder, and moving `<room_unknown>` into the
  cached prefix.

**Slice 6 Task 4 step 1 — outbound.** The loop is closed: a WhatsApp guest now receives replies.
Until this, everything the app wrote stayed inside the building.

- `Whatsapp::SendMessageJob`, on the `critical` queue, serialized per conversation (two replies
  racing each other would reach a phone in whatever order the network settled, and on this channel
  that order is final).
- **It waits for the translation, and that is the whole design decision.** On the web the overlay
  lands a second later into a page already showing the words, which is why
  `Ai::TranslateMessageJob` deliberately does not block (see `known-issues.md`). There is no overlay
  on WhatsApp: sending the receptionist's Bosnian and then the guest's German means the guest gets
  two messages, one unreadable. So the job re-enqueues itself while `Message#translation_in_flight?`,
  bounded by `MAX_ATTEMPTS`, which is **derived from `Ai::TranslationWatchdogJob::BUDGET`** rather
  than typed — the watchdog is what guarantees the wait ends, so widening one must not strand the
  other. When the wait runs out the original goes, because the original always beats silence.
- **It never sends anything the guest cannot already see.** The guard is `guest_visible?` — the same
  condition `broadcast_to_guest` uses — and it lives in `Conversation#broadcast_new_message`
  alongside it rather than in each of the six methods that post a message. That is the fifth
  guest-facing read of `messages` in the app and the only one where a mistake cannot be taken back:
  an internal note on the web is a wrong render, on WhatsApp it is on the guest's phone forever.
- Wired for **every** guest-visible non-guest message, not just staff replies — the concierge's own
  answers, the degraded notice and the request receipts are equally invisible until something sends
  them. A guest asked for their room by a reply that never arrives is the first thing a demo hits.
- `Message#claim_delivery!` (`local → queued`, one atomic statement) is the outbound counterpart of
  `#claim_translation!`, and exists for a sharper reason: a duplicate send cannot be recalled, and
  the guest simply sees the hotel say the same thing twice.
- Failures are told to the receptionist **in words**, on the transcript, and only on this channel:
  `WindowClosedError` (Meta's rule, not a fault — the guest must message first) marks the message
  `failed` and renders a red line saying exactly that; a hard `ApiError` does the same and reports to
  Sentry; a `RateLimitedError` is **re-raised** so the queue retries rather than dropping a reply.
- `FakeWhatsappProvider` (`test/support/`) subclasses the real port, the same way `FakeClaude` does
  around `Ai::Client`. What goes out on the wire is still asserted against WebMock in
  `meta_cloud_provider_test.rb`; this is for testing what the *job* decides to hand it.
- **Two more tests that passed for the wrong reason, both found by breaking the code.** Deleting the
  `conversation.whatsapp?` guard from the job left everything green, because no fixture guest session
  carries a `phone_e164` and the send was really being stopped by "no recipient" — the web guest in
  that test now has a phone. Deleting the same guard from the view left everything green too,
  because nothing writes a delivery status on the web, so the notice had nothing to render — that
  test now forces `failed` on a web message. Both are red without their guard now.

**Slice 6 Task 4 step 3, first half — the channel settings screen.** `/staff/whatsapp_channel/edit`.
Until this, a `whatsapp_channels` row could only be created by hand on the production box, which is
the "hidden manual step" this project's own rules forbid — onboarding a hotel was an engineering
task. Now it is a hotel-admin one.

- Singular and id-less, the shape `hotel_settings` and `preferences` already use: there is no
  request that could name another hotel's channel. No `#new`/`#create` — `#edit` renders the form
  whether or not a row exists and `#update` creates it on first save, so the permitted-parameter
  list lives in one place.
- **`#edit` is authorized as a read (`:show?`), and the form is gated separately on
  `policy(@channel).update?`.** A receptionist at 23:00 has to be able to answer "I messaged you on
  WhatsApp and nobody replied" — is the number live, did anything ever arrive — which is a shift
  question. Changing the hotel's own published number is not. They get the state panel and no
  fields, rather than an editable form that refuses them on submit.
- `verified_at`, `last_inbound_at` and `last_error` are deliberately **not** permitted: they are
  written by what actually happens on the channel (`Whatsapp::InboundRouter` stamps `last_inbound_at`
  on every real delivery), and a form that could set them would let a hotel tell itself a number is
  working when nothing has ever arrived on it.
- The `phone_number_id` field carries a hint saying what it really is, because nobody would guess
  from the name that it is the routing key and that a wrong value means guest messages reach nobody.
  Another hotel's value is refused by the global unique index and surfaces as a readable error.

**Slice 6 Task 4 step 3, second half — the guest-facing door.** The landing page now offers
"Chat on WhatsApp" next to the QR chat, in all four guest locales.

- Rendered **only** for an `active` channel. A channel that exists but is `pending` or `disabled` is
  a number nobody is answering, and a button leading there is worse than no button — the guest
  writes into silence and concludes the hotel is ignoring them.
- `GuestChatHelper#guest_whatsapp_url` builds Meta's own `wa.me` click-to-chat link. Two details
  that would each break it quietly: the number is stripped to **digits only** (a `+` in a wa.me path
  produces a dead link, and nothing would report it), and the greeting is **prefilled**, because
  Meta's 24-hour window only opens once the *guest* writes — a button that opens an empty composer
  leaves them wondering what to say.
- **Nothing identifying is in the link** — no token, no session, no ids — which is what makes it
  safe to print, screenshot and share, which is what people do with it. The room binding happens in
  conversation (`Ai::Tools#set_guest_room`). A test pins the whole URL shape rather than only the
  absence, so a future parameter has to be added deliberately.

**Slice 6 Task 4 steps 2 and 4 — the template registry, and the runbook.** With these, **Slice 6 is
complete**: every step of all four tasks.

- `whatsapp_templates` — a hotel's record of what it registered with Meta and what Meta said.
  **This table records Meta's decisions and makes none of them**, which is the sentence the whole
  design follows from. `#usable?` is a cheap pre-check that saves a doomed API call, never a
  permission this app grants — Meta refuses an unapproved template whatever the row says.
- Identity is **name + language**: "welcome" in bs and "welcome" in de are two separately-approved
  objects at Meta, so the unique index covers both and is scoped to the hotel. Unlike
  `phone_number_id` this is *not* a routing key — two hotels each having a "welcome" is ordinary, and
  a global index would let the first hotel to register a common name take it from everyone else.
- `status` and `rejection_reason` **are** writable from the form, unlike the channel screen's
  `verified_at`/`last_inbound_at` — and the inconsistency is deliberate. Those are written by things
  that really happen inside this app, so a form could make them lie. These are written by Meta, in
  Meta's dashboard, where this app has no reach: transcription is the only way they can be here.
- **No bulk-send UI, on purpose**, and adding one is not a small feature: an un-opted-in send risks
  the hotel's number, which is the hotel's asset and not ours.
- **`render.yaml` now carries the three WhatsApp secrets** (`WHATSAPP_ACCESS_TOKEN`,
  `WHATSAPP_APP_SECRET`, `WHATSAPP_WEBHOOK_VERIFY_TOKEN`, all `sync: false`) plus the commented
  `WHATSAPP_API_VERSION` override. This was the last hidden manual step in the slice.
- `docs/whatsapp-onboarding.md` gained **section 4, "Connecting a number — the actual steps"**: the
  three secrets and where each comes from, the exact Meta webhook configuration, the three fields a
  hotel fills in, and a four-step ordered check that each proves something the next one assumes
  (message in → routed → concierge asks → reply arrives). It is the section to read with a number in
  hand; sections 1–3 remain about lead times.
- **A second sighting of the mass browser-launch failure**, this time locally: 38 errors out of 41,
  with the immediately preceding and following runs both 41/41 green. Recorded in
  `known-issues.md` — including that **the error text was not captured**, so it is not confirmed to
  be the same fault CI saw. Nothing was changed in the harness for it (engineering rule 6); the entry
  now says to capture full output first and gives ~1 in 8 as the baseline to beat.

**Slice 7 Task 1 — `ai_usage_days`, the rollup every analytics number and the budget guard read.**

- One row per hotel per day per **kind**, because "what did the concierge cost us versus translation"
  is the first question anyone asks and a rollup that has merged them cannot answer it. `enum :kind,
  AiRun.kinds` — literally AiRun's own mapping, shared rather than copied, so the two cannot drift
  about which integer means `translation`.
- **Postgres does the addition**, via `upsert_all` with an `on_duplicate` that reads the row's
  current value. Expressed as Rails' own upsert rather than raw SQL specifically so it needs none of
  the tenant-scope escape hatches the grep tripwire polices.
- Written from `AiRun`'s own `after_create_commit`, not from the two jobs that build runs — so a
  third caller cannot forget it, the same reasoning `Conversation#broadcast_new_message` documents.
- `AiUsageDay.rebuild_for` (the backfill, `rake ai_usage:backfill`) **replaces rather than
  accumulates** — the opposite of the live path, which is why they are two methods named for what
  they do rather than one with a flag. Run twice it gives the same numbers, and it is also the repair
  to reach for if these are ever doubted.
- `AiRun.tokens_used_today` now reads the rollup. Its own tests pass **untouched**, which was the
  check that this stayed a refactor rather than a product change; `budget_exhausted_for?` still reads
  zero as "exhausted, no AI".
- **One test asserts the mechanism, not the outcome, and says so.** Every other test in the file
  passes against a read-modify-write — *measured*, not assumed — because a single-threaded test never
  produces the interleaving that loses an update. So it pins the SQL, the same way this project's
  constant-time signature test asserts the comparison used rather than the timing. Two more tests
  were strengthened after their first break came back green: the backfill's date test now uses two
  timestamps that are the same UTC day and different Sarajevo days, and the isolation test now says
  plainly that `hotel.ai_runs` is *not* what it proves (under the rake task's `with_tenant`, a bare
  `AiRun.all` is scoped identically).

**Slice 7 Task 2 — the analytics pages.** `Analytics::HotelReport` is one object, read by both the
hotel's own screen and the platform rollup, so the two can never show different numbers for the same
thing. A test asserts they agree.

- It answers **five questions and nothing else**; the test applied to each candidate was whether it
  changes what somebody would do. The unanswered questions come back as a **list, not a count**, and
  are the largest thing on the page — "guests keep asking about parking" tells a hotel exactly what
  to write down, which "7 unanswered" does not.
- **"What is this costing us" is deliberately absent from the hotel's page**, departing from the
  brief's own wording: a hotel pays Hospello, not per token, so a token count is a number it cannot
  act on. It sees `budget_used_fraction` — proximity to the ceiling that silences its assistant —
  and tokens appear on the platform page, where they really are the cost driver.
- Response time is a **median** (one request nobody noticed over a weekend drags a mean into
  uselessness) and measured to **acceptance**, not completion, because that is what reception
  controls. `overdue_now` is deliberately **not** scoped to the range: "what is late" is about now.
- `escalation_rate` is **nil, not 0**, when there was no traffic. "0% escalated" reads as a triumph,
  and a hotel with no guests has not achieved one.
- The hotel page is **hotel-admin only** (`HotelAnalyticsPolicy`). A receptionist reading "how often
  did the assistant hand over to us" is reading a page about their own performance.
- Ranges are clamped, never refused — a future end, a start after its end, a five-year span — and
  the page **states the range it really showed**, because a page quietly showing something other than
  what was asked for is the kind of wrong nobody catches.
- **Two bugs found by the work rather than by review.** Four report tests initially passed against
  nothing, because the setup held a `HotelReport` instead of a snapshot of its numbers and the object
  re-queries on every call. And building the platform page raised `NoTenantSet` — a report is lazy,
  so one built inside `with_tenant` in a controller ran its queries in the *template*, outside the
  tenant. That is fail-closed working. Fixed in the report (`#for_hotel`), so a report is now safe to
  read anywhere rather than carrying an unwritten requirement about ambient state.

**Slice 7 Task 3 — retention, and the right to be forgotten.** Complete. The task with legal weight,
and the one where a bug is unrecoverable in both directions: data kept too long is a liability, data
deleted wrongly is gone. **Read `app/services/retention/policy.rb` first** — it is the whole task in
one file, and every number anywhere else in this feature comes from it.

- **The policy was written before anything that deletes**, deliberately, and it names *every* table
  with a `hotel_id` — including the ones kept for as long as the hotel is a customer, because those
  are the decisions most likely to be made by omission. A test scans the models the same way
  `test/tenancy/tenant_declaration_test.rb` does, so a future table cannot arrive without a
  retention decision. Three windows: **90 days** for the guest's own conversation (the purpose ends
  with the stay; a quarter covers anything they will realistically raise afterwards), **365** for
  the hotel's operational record of a request once the guest's part is stripped out of it, **30**
  for raw provider callbacks, which are a verbatim second copy of data already held properly
  elsewhere.
- **`Analytics::HotelReport::MAX_DAYS` now reads the policy** (366 → 90), which is what the previous
  handover asked for. Conversations and messages are deleted at 90 days, so a year-long range would
  have shown a hotel nine months of zeros that read as a collapse in business rather than as a purge
  working. The cap follows the policy, never the other way round.
- **The purge has two anchors for the chat, not one.** Deleting expired guest sessions alone would
  keep a WhatsApp regular's first conversation forever, because their identity is renewed every time
  they write (`GuestSession#renew_for_whatsapp!`). So conversations are purged on their own last
  message too, with `COALESCE` onto `created_at` — a conversation the guest opened and never wrote
  in has a null `last_message_at`, and `NULL < cutoff` is not true, which is exactly the shape of
  bug nobody notices for a year.
- `webhook_events` is purged **outside** the per-hotel loop, and that is not an oversight: it is the
  one non-tenant-scoped table, and a delivery that never routed has no hotel at all — a loop over
  hotels would never reach one, and those rows carry a real phone number and a real message.
- **`ServiceRequest.anonymize_all!` is one definition of what taking the guest out of a request
  means**, called by both the nightly sweep and erasure-on-request. Every column it clears and every
  column it keeps is named with why. It writes through `update_all`, which is what gets it past
  `#details_original_is_immutable_after_creation` — that guard exists to stop a *translation*
  overwriting an original, and retention has to be visibly a different kind of write to be allowed
  past it. A test pins that the ordinary way in is still refused. New column `anonymized_at` makes
  the sweep incremental rather than rewriting a year of rows every night.
- **`Retention::GuestErasure`** is the purge's opposite in three ways and each changes the design:
  immediate, for one identity (so it runs in a transaction), and **provable afterwards**. The audit
  entry carries the guest session's id and counts and **never a name or a number** — the proof of an
  erasure must not be a copy of what it erased, and a test scans the whole audit row for both.
- `/platform/hotels/:id/guest_erasures`, linked from the hotel page. Platform-admin only, which is a
  different question from "who may read this data": a hotel_admin deleting a guest's transcript is
  indistinguishable from a hotel destroying a complaint. The confirmation **names what is about to
  be destroyed** rather than asking "are you sure?", from the same scopes that then destroy it.
- **The last step is the one that makes it stick.** `test/i18n/privacy_notice_retention_test.rb`
  reads `Retention::Policy` and asserts its numbers appear in the guest privacy notice in all four
  languages — **and the reverse**, that no notice states a period the code does not keep, so "180
  days" cannot be added to the German copy alone and sit there for a year. The copy carries literal
  numbers rather than interpolating them from the policy **on purpose**: interpolation would make
  the test unable to fail, and a promise changing from 90 days to 60 has to be a change somebody
  makes to the sentence a guest reads, in every language, deliberately.
- **26 deliberate breaks, each restored**, and three of them found tests that could not fail: a
  batching test whose rows were really being removed by a cascade, an `ai_runs` cutoff with no
  fixture between the two windows, and two guarantees held by two independent layers each (the
  platform-admin check, and the cross-hotel lookup) where removing either alone left everything
  green. All three are recorded in the test files so nobody deletes a layer as redundant.
- `docs/runbook.md` gained two real sections (a guest asks to be forgotten; the retention purge),
  replacing nothing — the three reserved placeholders are still reserved.

---

## What to do next

**Slice 6 is complete** — every step of all four tasks. The write-ups above cover each; the two
files that show the whole thing working are `test/services/whatsapp/inbound_flow_test.rb` (a real
webhook payload through to a `ServiceRequest`) and `docs/whatsapp-onboarding.md` section 4
(connecting a real number).

1. **Slice 7 — start at Task 4, the demo seed. [`docs/plan/slice-7-tasks.md`](docs/plan/slice-7-tasks.md)
   is written**, five tasks with schemas, steps and traps, the same shape slices 4–6 used. Read it
   rather than the plan's one-paragraph summary; `docs/plan/implementation-plan.md` remains the
   contract if the two ever disagree.

   **Tasks 1, 2 and 3 are done** (see their write-ups above). **Start at Task 4 — the demo seed**
   (`db/seeds/demo.rb`, whose `SEED_DEMO=1` wiring already exists; only the content is missing),
   then Task 5, hardening and the walkthrough that ends the project.

   Two things Task 3 leaves for Task 4 to get right, both cheap if you know them now and annoying
   if you find out afterwards:
   - **The seed's dates decide whether the demo shows anything.** Anything it creates more than
     `Retention::Policy::GUEST_CHAT_DAYS` (90) days in the past is deleted by the first purge, and
     anything older than 90 days is invisible to the analytics pages, whose `MAX_DAYS` is now that
     same number. Seed inside the last few weeks.
   - **The seed will eventually be run against production** (the slice's own traps section says so).
     `Retention::PurgeExpiredGuestDataJob` is now scheduled daily in production, so a seed that
     writes plausible old data is a seed whose data disappears overnight — which is the *safe*
     direction, but it will look like a bug to whoever demos it.

   One item is worth flagging on its own: **`LIVE_AI=1` has still never run**, in any
   session, because no session has ever had an `ANTHROPIC_API_KEY`. Everything believed about prompt
   caching, real tool-call shapes and real token accounting rests on tests against `FakeClaude`.
   Slice 7 Task 5 step 6 is where that gets settled — treat its first run as a source of findings
   about Slices 3–5, not as a formality.

   Three things left undone in Slice 6, all deliberate, none blocking:
   - **A system test for the WhatsApp settings screen** (the brief names
     `test/system/whatsapp_channel_settings_test.rb`). Everything it would cover is covered by
     `test/controllers/staff/whatsapp_channels_controller_test.rb`, and this suite's house rule is to
     drive only what needs a browser. If you add one, keep it short and single-purpose (rule 5).
   - **Non-text inbound messages** — a guest who sends a photo still gets silence. This was free
     while *everything* was silent; it is not any more, now that replies really do leave. Recorded in
     `docs/plan/known-issues.md` with the cheapest honest fix.
   - **Nothing sends a template yet.** The registry records them and `Whatsapp::Provider
     #send_template` exists and is tested, but no caller uses it — deliberately, since the opt-in
     that would make a proactive send legitimate is collected at check-in and this slice ships no
     bulk-send UI.

   Meta's free test number covers everything built so far — five test recipients, no business
   verification, no BSP decision needed. `docs/whatsapp-onboarding.md` section 4 is the checklist.
2. **Bump Rails before 2026-10-07**, when 8.0.5.1 leaves support. Brakeman already says so on every
   run; it no longer fails the build (`-w2`), so this needs a human to actually schedule it.
3. **Have a lawyer read the privacy notice before a pilot, and now there is a specific thing to ask
   about.** The notice states real numbers as of Task 3 (90 days for the chat, 365 for the
   anonymized request record) and those are *product* decisions defended in
   `app/services/retention/policy.rb`, not legal advice. The pending-legal-review marker is still on
   the notice and still test-protected. If a lawyer changes a number, change it in the policy — the
   four locale files then fail their test until they are updated, which is the point.
4. **Small, deliberate gaps left by Slice 5 Task 4**, worth a decision before a pilot rather than
   fixing on a hunch: ActiveRecord attribute names inside composed validation errors are still
   hardcoded English (rails-i18n translates the error text itself, not the field name — a Bosnian
   reader sees `"Name je već zauzet"`), and two exception-relayed alerts
   (`Staff::RoomsController#bulk_create`'s absurd-bulk-paste guard,
   `Staff::ServiceRequestsController#transition`'s two-tabs-racing-a-status-change guard) are still
   raw English `e.message` — both are defensive edge cases rather than routine confirmations. See
   Task 4's Piece 3 section above for the full reasoning. (The Bosnian pluralization gap that used to
   be listed here is fixed — see `bafbe63`.)

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
- **There is a job that deletes things now, and it runs every night in production.** Anything you
  add that stores something about a guest needs a line in `app/services/retention/policy.rb` —
  `test/services/retention/policy_test.rb` fails on any new table with a `hotel_id` that has no
  decision written against it, which is deliberate and is not a test to route around. And if you
  ever change one of the policy's numbers, the guest privacy notice in **all four** languages has to
  change in the same commit; `test/i18n/privacy_notice_retention_test.rb` fails in both directions
  until it does.
- **Fixture accessors query the database, so reading one *after* a deletion raises
  `RecordNotFound`** — which reads as a broken test rather than as the deletion the test exists to
  assert. In any test that erases or purges, capture `messages(:x).id` into a local *before* the
  call. Cost twenty minutes in this session.
- **`Analytics::HotelReport::MAX_DAYS` is 90 now, not 366**, and it is derived from the retention
  policy rather than typed. If an analytics page ever needs to look further back, the question to
  answer first is "does that data still exist", not "can we raise the cap".
- **Check [docs/plan/known-issues.md](docs/plan/known-issues.md) before fixing anything that looks
  broken.** Several things that look like bugs are deliberate and documented, and two plausible-
  sounding claims in there have been investigated and are false.
- **A green local run does not mean a green CI run.** Nobody checked the Actions tab for three days
  of work, and the whole build was red the entire time. Check it.
- **Run `bin/rails test:system` too, not just `bin/rails test`, whenever you touch a fixture.**
  Learned again the hard way during Slice 3: adding `test/fixtures/kb_entries.yml` broke four
  browser tests that had assumed an empty table, `bin/rails test` stayed green, and three
  consecutive commits went red on CI before anyone looked. Fixtures are global — a new row in one
  file changes what every test in the suite sees.
- **`bin/rails test:system` needs a chromedriver that matches the container's Chrome, and the
  container may not ship one.** On 2026-08-11 a fresh machine had Chrome 151 in `/usr/bin` and
  chromedriver **147** in `$PATH` — all 41 system tests errored at once with
  `Selenium::WebDriver::Error::SessionNotCreatedError: This version of ChromeDriver only supports
  Chrome version 147`. Selenium Manager could not self-heal because the network policy blocks
  `googlechromelabs.github.io`. `storage.googleapis.com` **is** reachable, so the fix is one download:
  ```bash
  V=$(google-chrome --version | grep -oE '[0-9.]+')
  curl -sSo /tmp/cd.zip "https://storage.googleapis.com/chrome-for-testing-public/$V/linux64/chromedriver-linux64.zip"
  unzip -oq /tmp/cd.zip -d /tmp && chmod +x /tmp/chromedriver-linux64/chromedriver
  export SE_CHROMEDRIVER=/tmp/chromedriver-linux64/chromedriver
  ```
  This is an environment fact, not a repo bug — nothing was committed for it. If you see a *mass*
  system-test failure, check the driver/browser versions before reading it as a regression; note that
  the failure surfaces as a stack trace from screenshot capture, which hides the real cause unless
  you run a single file and read the top of the output.
- **Don't run `bin/rails test:system` in the background while running unit tests in the foreground.**
  Both use `hospello_test`: parallel unit runs get suffixed databases, but a batch under the
  50-test parallelization threshold runs single-process on the unsuffixed one, straight into the
  system suite's fixtures. Cost one unexplained error in an otherwise-clean break/restore loop
  before it was spotted; 13 consecutive clean runs afterwards.
- **Don't remove the leak-detection settings** in `test/application_system_test_case.rb`. They look
  like belt-and-braces and they are not: without them every system test that signs in and then
  clicks fails on CI, and passes locally, which is the worst possible failure shape.
- **rails-i18n (already a dependency) ships its own Bosnian translations for standard Rails/
  ActiveRecord strings** — validation messages ("has already been taken" → "je već zauzet"),
  `time_ago_in_words`, pluralization — the moment `I18n.locale` is `:bs`, with zero work from this
  app. Discovered while making the staff workspace speak Bosnian (Slice 5 Task 4): a receptionist now
  sees composed messages like `"Name je već zauzet"` — the error text translated, the attribute name
  not (this app has no `activerecord.attributes.*` translations; see that task's write-up above for
  the deliberate scope line). Don't mistake the mixed-language result for a bug before checking which
  half is which.
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
- **Posting a raw String body through `ActionDispatch::IntegrationTest` (`post path, params: raw_json_string, headers: {...}`)** — needed for `Webhooks::WhatsappController`'s tests, and Slice 6
  Tasks 3–4 will likely write more of them — prints `rack/mock_request.rb:148: warning: literal
  string will be frozen in the future` on a bare literal. Harmless (Ruby 3.4's "chilled string"
  transition; Rack::MockRequest mutates the string internally), not a bug in this app, but noisy in
  CI logs. Fix: `+"..."` on the literal, not a `# frozen_string_literal` pragma fight — see
  `test/controllers/webhooks/whatsapp_controller_test.rb` for the pattern.
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
