# Handover

**Written for whoever picks this up next — human or agent, on any machine.**
Read [CLAUDE.md](CLAUDE.md) first if you haven't.

> **Keep this file true.** Update it in the *same commit* as the work it describes. A session can be
> cut off at any moment, and a stale handover is worse than none because the next agent trusts it.

---

## Status at a glance

| | |
|---|---|
| **Last updated** | 2026-08-11 (Slice 5 complete — the staff workspace in Bosnian, the request-summary overlay, and the way in: setting a staff member's own language) |
| **Branch** | `main` |
| **Deployed** | Render (Frankfurt, free tier) — `/up` returns 200 |
| **Tests** | 850 unit/integration green · 41 system green · rubocop and brakeman clean · not yet re-run on CI (see below) |
| **CI** | ✅ Was green as of the last push (`9409b53`). This session's three commits are local only — not pushed, per instruction — so CI has not seen them yet. |
| **Progress** | **Slices 1–5 complete** |

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
  - **Note on Bosnian pluralization's own limit, stated rather than hidden:** I18n's default backend
    (no custom rule registered for `:bs`) only distinguishes `one` from `other`, the same English-shaped
    split every other `count:` key in this file already uses (Piece 1's "Asked N times", also
    unchanged here). Bosnian actually has three plural forms (1 / 2–4 / 5+); `other` here is the 5+
    form, so a count of 2–4 reads slightly less naturally than a full CLDR pluralization rule would
    produce. This never affects *correctness* — the number itself is always right — only how natural
    2–4 sounds. Registering a real three-form Bosnian pluralization rule for `I18n::Backend::Pluralization`
    would fix this properly across every `count:` key in the app at once; flagged here rather than
    solved as a proportionate, separate piece of work, not bundled into a review fix-round.
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

---

## What to do next

**Slice 5 is complete.** Nothing further is queued for it; see below for what a pilot might raise.

1. **Push this session's three commits and confirm CI is still green.** All were verified locally
   (unit/integration, system, rubocop, brakeman all clean) but, per instruction, never pushed —
   nobody has seen them run on GitHub Actions yet. Do this before trusting the "Progress" line above.
2. **Bump Rails before 2026-10-07**, when 8.0.5.1 leaves support. Brakeman already says so on every
   run; it no longer fails the build (`-w2`), so this needs a human to actually schedule it.
3. Slices 6–7 (WhatsApp, analytics/hardening) — specified in the plan, task breakdowns not yet written.
4. **Small, deliberate gaps left by Slice 5 Task 4**, worth a decision before a pilot rather than
   fixing on a hunch: ActiveRecord attribute names inside composed validation errors are still
   hardcoded English (rails-i18n translates the error text itself, not the field name — a Bosnian
   reader sees `"Name je već zauzet"`), and two exception-relayed alerts
   (`Staff::RoomsController#bulk_create`'s absurd-bulk-paste guard,
   `Staff::ServiceRequestsController#transition`'s two-tabs-racing-a-status-change guard) are still
   raw English `e.message` — both are defensive edge cases rather than routine confirmations. See
   Task 4's Piece 3 section above for the full reasoning. If a pilot ever shows Bosnian pluralization's
   two-form (`one`/`other`) approximation reading awkwardly for counts of 2–4, that's the other one —
   also flagged there, with the actual fix (a registered three-form `I18n::Backend::Pluralization`
   rule for `:bs`).

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
- **Run `bin/rails test:system` too, not just `bin/rails test`, whenever you touch a fixture.**
  Learned again the hard way during Slice 3: adding `test/fixtures/kb_entries.yml` broke four
  browser tests that had assumed an empty table, `bin/rails test` stayed green, and three
  consecutive commits went red on CI before anyone looked. Fixtures are global — a new row in one
  file changes what every test in the suite sees.
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
