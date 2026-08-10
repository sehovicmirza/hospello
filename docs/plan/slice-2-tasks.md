# Slice 2 — Guest web chat and reception inbox (human-only, no AI yet)

Demo at end of slice: a guest scans the hotel's QR code on a phone, enters their name and room
number, picks Arabic, and starts chatting. A receptionist sees the message appear live — no page
refresh — and replies. The guest sees the reply appear. The guest closes the browser, returns the
next day, and their conversation is still there.

**Why humans first, before the AI:** the spec requires that when the AI or translation is
unavailable, a guest can still reach reception — no dead ends. If the AI shipped first, the
degradation message ("our team will reply shortly") would be a lie, because staff would have no way
to reply. Building the human path first makes acceptance scenario 12 structurally true from here on,
and the AI in Slice 3 becomes an enhancement layered on a working product rather than a dependency.

Everything in Slice 1 is in place: `Hotel`, `Room`, `User`, `Department`, `RequestCategory`,
`AuditLog`; `TenantScoped`; `Staff::BaseController` (sets `Current.hotel` + the acts_as_tenant
tenant); `Platform::BaseController`; `Current.user/hotel/session`; Pundit; the tenancy test suite;
`BrandingHelper#hotel_brand_style(hotel)` emitting `--brand-primary` / `--brand-secondary` /
`--brand-on-primary` CSS custom properties; `Hotel#find_active_room(number)` (normalizes and returns
an active `Room` or nil); `HotelQrCode` encoding `https://APP_HOST/h/<slug>`; the staff layout and
nav; rack-attack; Solid Queue in Puma with the `critical`/`ai`/`default`/`low` queues.

Test framework: Minitest + fixtures. `bin/rails test`, `bin/rails test:system`.

---

### Task 1: The guest session — landing page, entry form, cookie identity

**Why this task exists:** acceptance scenario 3 — "a guest scans the QR code, enters a full name and
valid room number without providing a phone number, selects Arabic, and starts a persistent web
chat." This is also where the product's honesty about identity begins: the guest is **unverified**
and stays that way.

**Files:**
- Create: `db/migrate/*_create_guest_sessions.rb`
- Create: `app/models/guest_session.rb`
- Create: `app/controllers/guest/base_controller.rb`, `app/controllers/guest/entries_controller.rb`
- Create: `app/views/guest/entries/show.html.erb` (landing + form), `app/views/layouts/guest.html.erb`
- Create: `app/views/guest/entries/_privacy_notice.html.erb`
- Create: `app/helpers/guest_locale_helper.rb`
- Create: `config/locales/guest.bs.yml`, `guest.en.yml`, `guest.de.yml`, `guest.ar.yml`
- Create: `test/models/guest_session_test.rb`, `test/controllers/guest/entries_controller_test.rb`
- Create: `test/system/guest_entry_test.rb`, `test/fixtures/guest_sessions.yml`
- Modify: `config/routes.rb`, `config/application.rb` (available_locales), `test/tenancy/cross_tenant_access_test.rb`

**Schema — `guest_sessions`:**
- `hotel_id` bigint null: false, FK
- `room_id` bigint FK, **nullable** (WhatsApp guests in Slice 6 start roomless; web guests always have one)
- `channel` integer null: false, default 0 (enum: `web: 0`, `whatsapp: 1`)
- `token_digest` string — SHA-256 of the cookie token; index. Nullable (WhatsApp sessions have none).
- `phone_e164` string — optional for web, the identity key for WhatsApp.
  Partial unique index `[hotel_id, phone_e164] WHERE channel = 1`.
- `guest_name` string null: false
- `locale` string null: false, default "en"
- `identity_status` integer null: false, default 0 (enum: `unverified: 0`, `staff_verified: 1`)
- `privacy_accepted_at` datetime null: false
- `status` integer null: false, default 0 (enum: `active: 0`, `blocked: 1`)
- `last_seen_at` datetime, `expires_at` datetime null: false
- timestamps; index `[hotel_id, last_seen_at]`

**Interfaces produced (Slice 2 Task 2 and Slice 6 both depend on these):**
- `GuestSession.authenticate_by_token(raw_token)` → an active, unexpired session or nil.
- `GuestSession#touch_activity!` → bumps `last_seen_at` and extends `expires_at` by 7 days,
  capped at 21 days from creation.
- `Guest::BaseController` — resolves the cookie to `Current.guest_session`, sets
  `Current.hotel` and the acts_as_tenant tenant from **the session's hotel** (never from a URL
  parameter — a guest request must never be able to name another hotel), and renders the
  re-entry page when the cookie is missing, expired, or blocked.
- `hotel_landing_path(slug)` → `/h/:slug`, matching `HotelQrCode`'s URL exactly.

- [ ] **Step 1: Write the failing model tests**

```ruby
# test/models/guest_session_test.rb (excerpt)
test "authenticate_by_token finds an active session by its token digest" do
  hotel = hotels(:stari_grad)
  ActsAsTenant.with_tenant(hotel) do
    raw = SecureRandom.urlsafe_base64(32)
    session = hotel.guest_sessions.create!(
      guest_name: "Aisha", room: rooms(:stari_101), locale: "ar",
      privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
      token_digest: GuestSession.digest(raw)
    )
    assert_equal session, GuestSession.authenticate_by_token(raw)
  end
end

test "authenticate_by_token rejects an expired session" # expires_at in the past -> nil
test "authenticate_by_token rejects a blocked session"  # status: :blocked -> nil
test "authenticate_by_token returns nil for garbage"    # and must not raise
test "the raw token is never stored" # assert_nil GuestSession.column_names.find { _1 == "token" }

test "touch_activity! extends expiry but never past 21 days from creation" do
  # create with created_at 20.days.ago, touch, assert expires_at <= created_at + 21.days
end

test "a new session is always unverified" do
  # even when created by staff; identity_status must be :unverified
end
```

`GuestSession.digest(raw)` is `Digest::SHA256.hexdigest(raw)`. Comparing digests rather than storing
the token means a database leak does not hand over live guest sessions.

- [ ] **Step 2: Write the failing controller tests**

`test/controllers/guest/entries_controller_test.rb`:
- `GET /h/stari-grad` renders the landing page with the hotel's name, welcome message, and contact
  phone, and does **not** require any session
- `GET /h/nonexistent` → 404
- `GET /h/<suspended hotel>` renders a "not available" page, not the chat entry (a suspended hotel
  must not serve guests)
- posting a valid name + room number + locale + consent creates a `GuestSession`, sets the cookie,
  and redirects to the chat
- posting **without** a phone number succeeds (phone is optional — this is acceptance scenario 3)
- posting a room number that is not in the hotel's active room list re-renders the form with a
  friendly error and creates nothing
- posting without the consent checkbox re-renders with an error and creates nothing
- the created session is `unverified` **even if the request tries to set `identity_status`**
  (assert mass assignment is impossible)
- a request for hotel A's landing page can never create a session on hotel B (assert
  `Current.hotel` comes from the slug and the created session's `hotel_id` matches)

- [ ] **Step 3: Implement the model, controllers, and routes**

Routes:
```ruby
# The one public entry point per hotel. The printed QR code encodes exactly this.
get "/h/:hotel_slug", to: "guest/entries#show", as: :hotel_landing
post "/h/:hotel_slug", to: "guest/entries#create"

namespace :guest do
  # chat routes arrive in Task 2
end
```

`Guest::EntriesController` is the **only** guest controller that takes a hotel from the URL; it
inherits `ApplicationController` (not `Guest::BaseController`, which requires a session). It looks
the hotel up by slug, 404s on miss, and refuses suspended hotels.

Cookie: `cookies.signed[:hospello_guest] = { value: raw_token, httponly: true, same_site: :lax,
expires: 21.days.from_now }`. Sign it so a forged cookie cannot name another session; store only the
digest.

- [ ] **Step 4: The landing page and entry form**

Mobile-first, and the hotel — not Hospello — is the brand. The page carries
`<body style="<%= hotel_brand_style(@hotel) %>">` and every accent colour is a `var(--brand-primary)`
reference, so a hotel's colours flow through without a per-hotel stylesheet.

Above the form: hotel logo, hotel name, welcome image if present, the hotel's welcome message, and
the reception phone number as a **tappable `tel:` link**. Directly beneath that, in the guest's
language, a short line making clear this chat is not an emergency channel and naming what to do
instead (call reception, or the local emergency number). This is a spec requirement, not decoration.

The form asks for: full name (required), room number (required), preferred language (a select,
preselected from `Accept-Language` — see Step 5), phone (**optional, and labelled as optional**), and
a consent checkbox referencing the privacy notice. The privacy notice is a collapsible panel, short
and plain, and carries a visible marker that it is pilot copy pending legal review.

A discreet "Powered by Hospello" line renders only when `hotel.powered_by_visible`.

- [ ] **Step 5: Locale detection and the four guest languages**

`GuestLocaleHelper.detect(accept_language_header)` → the best match among `%w[bs en de ar]`,
defaulting to `en`. Parse quality values properly (`bs-BA;q=0.9`), and unit-test it against real
header strings including a malformed one.

`config/application.rb`: `config.i18n.available_locales = %i[bs en de ar]`,
`config.i18n.default_locale = :en`, and `config.i18n.fallbacks = true`.

Translate the landing page, form labels, validation messages, privacy notice, and the emergency line
into all four. Arabic is not an afterthought: `<html dir="rtl">` when the locale is Arabic, and the
layout must use CSS **logical** properties (`margin-inline-start`, `padding-inline`, `text-align:
start`) rather than left/right, so one stylesheet serves both directions. Add `dir="auto"` on any
element that renders guest-supplied text.

- [ ] **Step 6: System test**

`test/system/guest_entry_test.rb` — drive a real browser: visit `/h/stari-grad`, fill in name and
room, choose Arabic, leave the phone blank, accept the notice, submit, and assert the chat page
appears with `dir="rtl"` on `<html>`. Then revisit the landing URL and assert the guest goes straight
to the chat without re-entering anything (the persistence requirement).

Add a second test asserting an invalid room number keeps the guest on the form with a visible error.

- [ ] **Step 7: Extend the isolation suite, run everything, commit**

Add guest routes to `test/tenancy/cross_tenant_access_test.rb`: a guest session cookie issued by
hotel A must never resolve to hotel B's data.

---

### Task 2: The chat itself — conversations, messages, live updates

**Files:**
- Create: `db/migrate/*_create_conversations.rb`, `db/migrate/*_create_messages.rb`
- Create: `app/models/conversation.rb`, `app/models/message.rb`
- Create: `app/controllers/guest/chats_controller.rb`, `app/controllers/guest/messages_controller.rb`
- Create: `app/views/guest/chats/show.html.erb`, `app/views/guest/messages/_message.html.erb`,
  `app/views/guest/chats/_composer.html.erb`, `app/views/guest/chats/_quick_actions.html.erb`
- Create: `app/javascript/controllers/chat_resilience_controller.js`, `chat_scroll_controller.js`
- Create: `app/channels/conversation_channel.rb`
- Create: `test/models/conversation_test.rb`, `test/models/message_test.rb`
- Create: `test/controllers/guest/messages_controller_test.rb`
- Create: `test/system/guest_chat_test.rb`
- Create: `test/fixtures/conversations.yml`, `test/fixtures/messages.yml`
- Modify: `config/routes.rb`, `app/models/guest_session.rb`

**Schema — `conversations`:**
`hotel_id` null: false FK · `guest_session_id` null: false FK · `room_id` FK nullable ·
`channel` integer null: false default 0 · `status` integer null: false default 0
(`active: 0, escalated: 1, resolved: 2, expired: 3`) · `ai_mode` integer null: false default 0
(`auto: 0, paused: 1`) · `escalation_reason` integer nullable
(`guest_requested: 0, ai_uncertain: 1, ai_unavailable: 2, budget_exhausted: 3, staff_manual: 4`) ·
`escalated_at` datetime · `guest_locale` string · `last_guest_message_at` datetime ·
`last_message_at` datetime · `staff_unread_count` integer null: false default 0 · timestamps.

**The partial unique index is load-bearing** — add it in the migration:
```ruby
add_index :conversations, :guest_session_id, unique: true,
  where: "status IN (0, 1)", name: "index_conversations_one_live_per_guest_session"
```
It guarantees one live conversation per guest even when two requests race, which is exactly what
happens when a guest double-taps send on a slow phone connection. `Conversation.live_for(session)`
must `rescue ActiveRecord::RecordNotUnique` and re-find rather than propagating the error.

**Schema — `messages`:**
`hotel_id` null: false FK · `conversation_id` null: false FK · `sender_role` integer null: false
(`guest: 0, assistant: 1, staff: 2, system: 3`) · `sender_user_id` FK nullable ·
`body` text null: false (the original, never mutated) · `body_locale` string ·
`translated_body` text · `translated_locale` string ·
`translation_status` integer null: false default 0 (`not_needed: 0, pending: 1, translated: 2, failed: 3`) ·
`client_message_id` uuid — unique index `[conversation_id, client_message_id]`, the web dedupe key ·
`external_id` string — partial unique index where not null, the WhatsApp dedupe key (Slice 6) ·
`delivery_status` integer null: false default 0 (`local: 0, queued: 1, sent: 2, delivered: 3, read: 4, failed: 5`) ·
`delivered_at` datetime — **the single-writer delivery claim** used in Slice 5 ·
`metadata` jsonb null: false default {} · timestamps · index `[conversation_id, id]`.

Several of these columns (translation, delivery, external_id) are unused until Slices 5 and 6.
They are in this migration deliberately: adding them now costs nothing and avoids a later migration
against a table holding live guest conversations.

**Interfaces produced:**
- `Conversation.live_for(guest_session)` → the guest's live conversation, creating one if needed,
  race-safe.
- `Conversation#post_guest_message!(body:, client_message_id:)` → creates the Message, touches
  `last_guest_message_at`/`last_message_at`, increments `staff_unread_count`, all in one
  transaction, and broadcasts **after commit**. Returns the existing Message unchanged when
  `client_message_id` was already used (idempotent — a retried form submit must not double-post).
- `Conversation#post_staff_message!(user:, body:)` → same shape for the staff side, resetting
  `staff_unread_count`.
- Turbo stream names: `[conversation]` for the chat itself and `[hotel, :inbox]` for the staff list.

- [ ] **Step 1: Write the failing model tests**

Cover: `live_for` returns the same conversation twice in a row; `live_for` creates a new one after
the previous is resolved; **two concurrent `live_for` calls yield one conversation** (simulate by
inserting a conflicting row and asserting the `RecordNotUnique` path re-finds rather than raising);
`post_guest_message!` is idempotent on `client_message_id`; `post_guest_message!` increments the
unread count and `post_staff_message!` clears it; a message's `body` is never modified by any of it.

- [ ] **Step 2: Write the failing controller tests**

- `GET /guest/chat` without a cookie renders the re-entry page (not a 500, not a redirect loop)
- `POST /guest/messages` with a valid cookie creates one message and returns a Turbo Stream
- posting the **same `client_message_id` twice** creates exactly one message
- a message longer than 1000 characters is rejected with a friendly error
- an empty or whitespace-only message is rejected and creates nothing
- `GET /guest/messages?after=<id>` returns only messages newer than that id (the resync endpoint)
- a guest session for hotel A can never post into hotel B's conversation

- [ ] **Step 3: Implement models and controllers**

`Guest::BaseController` (from Task 1) does the tenant work; the chat and message controllers inherit
it. Rate-limit `create` with Rails' `rate_limit` on top of rack-attack's IP throttle, keyed by the
guest session, so one abusive session cannot flood the hotel while normal guests are unaffected.

- [ ] **Step 4: The chat UI**

Mobile-first, hotel-branded via the same `hotel_brand_style` custom properties. Message bubbles
distinguish guest / staff / system visually **and** with a text label for screen readers, never by
colour alone. Every bubble carries `dir="auto"`. Timestamps render in the hotel's timezone.

Above the composer on an empty conversation, quick-action chips — ask a question, extra towels or
bedding, room cleaning, report a problem, wake-up call, breakfast and dining, contact reception —
built from the hotel's **own** `RequestCategory` list plus a fixed "ask a question" and "contact
reception". Tapping one prefills the composer with an editable sentence in the guest's language; it
never sends anything by itself, because a request the guest didn't read is exactly what the
confirm-before-create rule exists to prevent. Free typing is always available.

States to build properly, not as afterthoughts: empty conversation (a warm greeting from the hotel,
not from "the AI"), sending, send failed with a retry affordance, and offline. Avoid AI vocabulary
entirely on the guest surface.

- [ ] **Step 5: Live updates and the resilience layer**

Broadcast `after_commit` to the `[conversation]` stream. Then build the recovery path, because a
guest's phone will drop the WebSocket constantly:

`chat_resilience_controller.js` — on Action Cable disconnect, on reconnect, and on
`visibilitychange` (the phone-unlocked-after-ten-minutes case, the single most common real-world
cable killer), fetch `GET /guest/messages?after=<last rendered id>` and append what's missing. While
disconnected, poll that endpoint every 20 seconds. The rule this encodes: **the database is the
truth and broadcasts are an enhancement** — a dropped broadcast costs one poll interval, never a
lost message.

`ConversationChannel` must verify the subscriber's guest session owns the conversation. Add a test
that a forged subscription to another conversation is rejected.

- [ ] **Step 6: System tests**

`test/system/guest_chat_test.rb` — a guest sends a message and sees it in the transcript; a quick
action prefills the composer without sending; an over-long message shows an error.

The cable-down test earns its keep: disable Action Cable, post a message from another session, and
assert it still appears via the polling fallback.

- [ ] **Step 7: Full suite, commit**

---

### Task 3: The reception inbox — see it live, reply, take over

**Why this task exists:** acceptance scenarios 7 and 9 begin here, and this is what makes the
"guest can always reach a human" guarantee real rather than aspirational.

**Files:**
- Create: `app/controllers/staff/conversations_controller.rb`, `app/controllers/staff/messages_controller.rb`
- Create: `app/views/staff/conversations/{index,show}.html.erb` and partials
  (`_conversation_row`, `_message`, `_composer`)
- Create: `app/policies/conversation_policy.rb`
- Create: `app/javascript/controllers/inbox_resilience_controller.js`
- Create: `app/channels/hotel_inbox_channel.rb`
- Create: `test/controllers/staff/conversations_controller_test.rb`
- Create: `test/system/reception_inbox_test.rb`, `test/system/guest_staff_live_test.rb`
- Modify: `config/routes.rb`, `app/views/layouts/staff.html.erb` (nav + unread badge),
  `test/tenancy/cross_tenant_access_test.rb`

- [ ] **Step 1: Write the failing controller tests**

- the inbox lists only `Current.hotel`'s conversations, newest activity first
- filter tabs (all / needs attention / resolved) and search by guest name or room number
- opening a conversation resets its `staff_unread_count`
- a staff reply creates a `Message` with `sender_role: :staff` and the acting `sender_user_id`
- hotel A's staff get 404 on hotel B's conversation (add to the isolation suite)
- a reply to a resolved conversation reopens it rather than silently vanishing

- [ ] **Step 2: Implement the inbox**

Two things a busy receptionist needs and rarely gets: **noticing** and **context**. Unread counts are
computed server-side at render (never incremented client-side, so they cannot drift). Conversations
needing attention sort first and carry a distinct colour plus a text label. The row shows guest name,
room, the **UNVERIFIED** badge, channel, last message preview, and time in the hotel's timezone.

Live updates broadcast to `[hotel, :inbox]`; `inbox_resilience_controller.js` mirrors the guest
side's reconnect/visibilitychange resync plus a 60-second poll while the cable is down.

- [ ] **Step 3: The conversation detail view**

Full transcript with clear sender attribution. Guest-visible replies and internal notes are visually
separated with an unmistakable boundary — internal notes get a distinct background, a lock icon, and
the literal words "Internal note — the guest cannot see this". Getting this wrong leaks staff
commentary to a guest, so it is worth being heavy-handed.

The composer states plainly where the message is going. Include the **Pause AI / Return to AI**
toggle now, flipping `conversation.ai_mode` and recording a system message in the transcript
("Reception took over the conversation") so the history explains itself. Nothing reads `ai_mode` yet
— Slice 3 does — but the staff-facing control and its audit trail belong with the inbox.

- [ ] **Step 4: The two-browser live test**

`test/system/guest_staff_live_test.rb` — the test that proves the slice. Two browser sessions: the
guest posts, the receptionist sees it appear without reloading; the receptionist replies, the guest
sees it appear. This is the demo, so it is worth the setup cost.

- [ ] **Step 5: Full suite, commit**
