# Slice 5 — Translation, and the lifeline it protects

Demo at end of slice: an Arabic-speaking guest and a Bosnian-speaking receptionist hold a
conversation, each reading their own language, neither aware there is a translation step. A message
whose room number came back mangled is delivered **in the original** rather than wrong. A
receptionist taps a chip and reads exactly what the guest actually typed. The staff workspace itself
switches to Bosnian.

**The rule this slice exists to enforce:** a translation is an *overlay*, never a replacement. The
original is what was said, it is immutable, and when translation is uncertain, slow, or wrong about
a number, the original is what gets delivered. Acceptance scenario 9 lives here, and scenario 12 —
"AI down, guest still reaches reception" — has to survive this slice adding a second AI call to the
one path that must never depend on one.

In place from Slices 1–4: `Ai::Client` + `FakeClaude`; `Ai::GenerateReplyJob` with per-conversation
serialization, the circuit breaker, and the budget guard that already lets translation run to 100%
while the concierge stops at 90%; `AiRun` with a `translation` kind that nothing writes yet;
`messages.translated_body` / `translated_locale` / `translation_status` and
`messages.delivery_status` / `delivered_at`, all present since Slice 2 and all still unused;
`TRANSLATION_MODEL` configured separately from `AI_MODEL` on purpose; `service_requests.summary`,
`details_original` and `original_locale`; the guest chat, the reception inbox, and the request board.

---

### Task 1: The digit guard, and the translator seam

**Why the digit guard comes first:** it is the one part of this slice that can make the product
actively harmful. "Room 305" translated as "room 350", "07:00" as "17:00", "12 KM" as "20 KM" — each
is a confident, fluent, wrong sentence that a receptionist will act on. Everything else in this
slice is machinery; this is the thing that decides whether the machinery is safe to turn on.

**Files:**
- Create: `app/services/ai/translator.rb`, `app/services/ai/digit_guard.rb`
- Create: `test/services/ai/digit_guard_test.rb`, `test/services/ai/translator_test.rb`
- Modify: `config/initializers/ai.rb` if a second model knob proves necessary (prefer not)

**Interfaces produced:**
- `Ai::DigitGuard.safe?(original:, translation:)` → false when the multiset of numbers differs.
- `Ai::DigitGuard.numbers_in(text)` → normalized decimal digits found in the text, **after**
  folding Eastern-Arabic (`٠١٢٣٤٥٦٧٨٩`), Persian (`۰۱۲۳۴۵۶۷۸۹`) and full-width forms to ASCII.
- `Ai::Translator.new.call(text:, from:, to:)` → `Ai::Translation` with `#text`, `#usage`,
  `#fell_back?` and `#reason`. Falls back to the original — never raises — on a timeout, an API
  error, a refusal, a truncation, an empty reply, or a digit-guard failure. `#reason` is kept rather
  than collapsed to a boolean: a rising `digit_mismatch` rate is a prompt problem, `timeout` is an
  infrastructure problem, and a `refusal` on a message about towels is worth someone looking at.

- [ ] **Step 1: The digit-guard corpus, written first**

A table test, not a handful of examples. At minimum:

```ruby
# safe
["Breakfast is at 07:00",        "Doručak je u 07:00"]
["Room 305",                     "الغرفة ٣٠٥"]          # Eastern-Arabic digits fold to 305
["Breakfast at 07:00",           "Doručak u 7:00"]      # a dropped leading zero is formatting
["It costs 12.5 KM",             "Košta 12,5 KM"]       # so is a decimal comma
# unsafe
["Room 305",                     "Room 350"]            # transposition
["07:00",                        "17:00"]               # a leading digit invented
["Room 305",                     "Room 305 and 306"]    # a number invented
["Is breakfast at 07:00 or 08:00?", "Kada je doručak?"] # numbers dropped entirely
["2 towels",                     "Par peškira"]         # a number spelled as a word
```

**The rule is strict equality of the numbers, as a multiset** — not merely "no invented numbers".
The last two rows are why. Allowing a drop would let a translation quietly turn "is breakfast at
07:00 or 08:00" into a question a receptionist cannot answer, and a number spelled as a word is the
same loss wearing better clothes.

That strictness has a real cost, and it is the right way round: a translation that writes a number
as a word falls back to the original, so the receptionist reads the guest's own language and taps to
see it. Readability suffers; correctness never does. If a pilot shows this firing often, fix the
translator's prompt — not the guard.

- [ ] **Step 2: The translator, and its four fallbacks**

One call, `effort: "low"`, on `TRANSLATION_MODEL`. The system prompt says: translate, preserve every
number, name, room and time exactly, output nothing but the translation. Guest and staff text goes
inside a data tag, same as the concierge's — a guest can write "ignore your instructions" into a
message a receptionist will read.

It falls back to the original text, marked, on: `Ai::TimeoutError`, any `Ai::Error`, a refusal or
truncation, a blank reply, and a digit-guard failure. **Never raises.** A translation that fails must
cost the message nothing.

- [ ] **Step 3: Full suite, commit**

---

### Task 2: Delivery — the claim column and the 15-second budget

**Why this is its own task:** the translate-then-deliver path has a race that produces the worst
possible outcome — the same message delivered twice, once translated and once not. A receptionist
seeing a guest's question appear twice, in two languages, learns not to trust the screen.

**Files:**
- Create: `app/jobs/ai/translate_message_job.rb`, `app/jobs/ai/delivery_watchdog_job.rb`
- Modify: `app/models/message.rb`, `app/models/conversation.rb`, `config/recurring.yml`
- Create: `test/jobs/ai/translate_message_job_test.rb`, `test/jobs/ai/delivery_watchdog_job_test.rb`

**The single-writer delivery claim.** Delivery is claimed with one atomic statement:

```ruby
Message.where(id: id, delivered_at: nil).update_all(delivered_at: Time.current) == 1
```

Whoever gets the `1` delivers; everyone else does nothing. Both the translate job and the watchdog
race for it, and exactly one wins. This is the same shape as `dedupe_key` and the one-live-draft
index: the guarantee is a database statement, not a check somebody remembered to run.

- [ ] **Step 1: Write the race tests first**

```ruby
test "a translation finishing at the same moment the watchdog fires delivers once"
test "a message already delivered untranslated is never re-delivered translated" # the overlay lands, the message does not resend
test "the watchdog delivers the original after the budget expires"
test "a delivered message's translation still lands as an overlay"
```

- [ ] **Step 2: The 15-second budget**

A guest waiting longer than this has decided the chat is broken. The watchdog (recurring, every
minute) delivers the original for anything past its budget and marks `translation_status: :failed`.
The translation, if it arrives later, is still written to `translated_body` — the overlay is useful
even when it was too slow to gate delivery on.

- [ ] **Step 3: Full suite, commit**

---

### Task 3: Both directions, and the chip

**Files:**
- Modify: `app/views/guest/messages/_message.html.erb`, `app/views/staff/conversations/_message.html.erb`
- Create: `app/javascript/controllers/translation_toggle_controller.js`
- Create: `test/system/translation_test.rb`
- Modify: `app/models/conversation.rb` (enqueue on both post paths)

**Which direction gets translated, and into what.** A guest message is translated into the hotel's
`staff_locale`; a staff message into the conversation's `guest_locale`. When those are the same
language, nothing is translated at all and `translation_status` stays `not_needed` — the commonest
case must cost nothing.

**Assistant messages are translated lazily.** The concierge already replies in the guest's language,
so the staff-facing translation of an AI message is only needed when a receptionist actually opens
that conversation. Translating every AI reply eagerly would double the slice's token cost for text
nobody reads.

**The chip.** Every translated bubble shows the translation with a control to reveal the original —
in both directions, and always in words rather than a flag icon (a flag is a country, not a
language, and gets this wrong for Arabic and for Bosnian both). A bubble that fell back shows the
original *labelled as untranslated* rather than silently looking like a normal message.

- [ ] **Step 1: Tests for the shape, not the wording**

```ruby
test "a guest message is translated into the hotel's staff language"
test "a staff reply is translated into the guest's language"
test "nothing is translated when both sides already share a language"
test "an assistant message is translated only when a staff member opens the conversation"
test "a message that fell back is shown as the original, and says so"
test "the original is always available, in both directions"
```

- [ ] **Step 2: Implement, then check the budget ordering**

Translation must keep working when the concierge has stopped. There is already a test asserting
90% vs 100% on `AiRun.budget_exhausted_for?`; this task adds the one that matters end to end: with
the hotel at 95% of budget, a guest message still reaches a receptionist **in their language** while
the concierge stays silent.

- [ ] **Step 3: System test, full suite, commit**

---

### Task 4: The staff workspace in Bosnian, and the request pipeline

**Files:**
- Create: `config/locales/staff.bs.yml`, `config/locales/staff.en.yml`
- Modify: every `app/views/staff/**` template, `app/helpers/staff_helper.rb`
- Modify: `app/models/service_request.rb`, `app/services/ai/translator.rb`
- Modify: `test/i18n/guest_locale_files_test.rb` (extend the family list, or rename it)

**This is the biggest mechanical change in the slice** and the one most likely to be done badly:
every hardcoded English string in the staff workspace moves into a locale file. Do it as its own
commit, separate from anything behavioural, so the diff is reviewable.

Per-user locale, not per-hotel: `User#locale` already exists and `Hotel::STAFF_LOCALES` is `bs`/`en`.
A Bosnian receptionist and an English manager work the same hotel.

**The request pipeline.** `service_requests.details_original` and `original_locale` are populated but
nothing reads them yet. A request confirmed in Arabic should show a receptionist a summary in *their*
language, with the guest's own words one tap away — the same overlay rule as messages, including the
digit guard, because a request summary is exactly where "2 towels at 18:00" becoming "20 towels at
8:00" does real damage.

- [ ] **Step 1: The locale-file structural test extended to the staff families**

The existing test in `test/i18n/guest_locale_files_test.rb` already covers `guest`, `degraded` and
`requests`. Add `staff` — and note that its locale list is `bs`/`en`, not the guest four, so the
test needs a per-family locale set rather than one constant.

- [ ] **Step 2: Move the strings, one screen at a time**

- [ ] **Step 3: The request summary overlay**

- [ ] **Step 4: Full suite, the four-language walkthrough, commit**

---

## Traps worth knowing before you start

- **`Message#body` is immutable and enforced** (`body_is_immutable_after_creation`). Translations go
  in `translated_body`. Do not be tempted to "fix" the original.
- **The guest surface has four languages; the staff surface has two.** They are different lists
  (`GuestLocaleHelper::SUPPORTED_LOCALES` vs `Hotel::STAFF_LOCALES`) and conflating them will produce
  a staff workspace that half-renders in German.
- **`config/locales/degraded.*.yml` and `requests.*.yml` are pre-translated on disk on purpose.**
  Nothing in this slice should replace them with live translation: they are the copy that runs when
  the model is unavailable, which is precisely when a translation call would fail too.
- **The budget guard's asymmetry is deliberate and already tested.** If you find yourself making
  translation stop at 90% "for consistency", read `AiRun.budget_exhausted_for?` and the comment above
  it first.
- **Assistant replies are already in the guest's language.** Translating them for the guest would be
  a round trip that can only make them worse.
