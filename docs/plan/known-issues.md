# Known issues, unverified assumptions, and deferred findings

Check here before "fixing" something. Several entries below look like bugs and are deliberate; one
looks like a passing test and is a hole.

---

## Open

### DEFERRED: a WhatsApp guest who sends a photo gets silence (Slice 6 Task 3)

Meta's inbound webhook carries `image`, `location`, `audio`, `document`, `sticker` and `contacts`
messages alongside `text`. Slice 6 handles **text only** — that scope line was drawn in Task 1
(`Whatsapp::InboundMessage`'s own class comment) and Task 3 implements it: a non-text message is
parsed, logged, and its `webhook_events` row settles as `ignored`. Nothing is written to the
transcript, so a receptionist never learns the guest sent anything.

**Why it was not "just" written in with a placeholder body.** `messages.body` is what a receptionist
reads, what the translator translates, and what the concierge sees as history. Inventing
`"[the guest sent a photo]"` means choosing that sentence in bs/en/de/ar, deciding whether the
concierge should try to answer it, and deciding whether it counts as an escalation — a copy and
product decision, not a mechanical addition.

**Why it costs nothing extra today:** there is no outbound path at all until Task 4, so a WhatsApp
guest receives silence whether or not this is handled. It becomes a real gap the moment Task 4 makes
replies send. The cheapest honest fix at that point is probably: persist the message with a
pre-translated system-notice body (the `degraded.*`/`requests.*` pattern this app already uses for
copy no model is allowed to write) and escalate rather than let the concierge answer a photo it
cannot see.

### DEFERRED: an erasure while a job for that guest is in flight leaves one failed job (Slice 7 Task 3)

`Retention::GuestErasure` deletes a guest session and, by cascade, its conversations and messages —
including a *live* conversation, which is the point: somebody asking to be forgotten is not told to
wait for the nightly sweep. If an `Ai::GenerateReplyJob`, `Ai::TranslateMessageJob` or
`Whatsapp::SendMessageJob` is queued for that conversation at that moment, it will fail on
`ActiveJob::DeserializationError` when it runs and land in the failed-jobs table.

**Blast radius: one noisy row for a guest who no longer exists.** No data is lost, nothing retries
into a wrong hotel, and nothing is written for the erased guest — the record it needed is gone,
which is the correct outcome, reached noisily.

**Why it is not fixed here.** The obvious fix is `discard_on ActiveJob::DeserializationError` in
`ApplicationJob` — the line is already there, commented out, from the Rails generator. Turning it on
is an app-wide behaviour change that would also silence a job failing because of a *bug* that
deleted a record it should not have, which is exactly the signal this codebase would want to keep.
Scoping it to the three jobs above is defensible but is a decision about job semantics, not about
retention, and it is not worth making inside a task with legal weight for an edge case that costs
one line in Mission Control.

**If you see these in the failed-jobs table after an erasure, that is this, and it is expected.**

### OPEN: mass browser-launch failure — narrowed to the harness, cause still unfound

**Symptom.** A system-test run errors on ~38 of its 41 tests, all inside
`Selenium::WebDriver::Driver#create_session` with `NoMethodError: undefined method 'closed?' for nil`
— Chrome failing to launch at all. Seen on CI four times and reproduces locally, historically about
one run in three.

**It is all-or-nothing, and that is the most useful fact about it.** A failing run typically passes
its first two or three tests and then every remaining one fails. So this is **one failure that wedges
the run**, not 38 independent races — which means the thing to find is what breaks after a few
driver cycles, not why a single launch is flaky.

#### Closed by experiment — do not re-test these

1. **The per-test driver quit in `teardown`.** DISPROVEN, and the opposite is true: removing it gave
   errors in all four runs (9, 1, 8, 3) against zero with it. It is load-bearing.
2. **`--disable-dev-shm-usage`** (the textbook remedy). NEUTRAL. Interleaved A/B, three alternating
   pairs on the same machine state: identical results every pair, including one where both sides
   failed. Not shipped.
3. **Leaked processes / file-descriptor exhaustion.** Ruled out by observation — zero stray
   `chromedriver` or Chrome processes after a failing run; `ulimit -n` is 1048576.
4. **Chrome, chromedriver, or macOS Gatekeeper.** RULED OUT decisively. A bare Selenium script that
   launches and quits headless Chrome 41 times — no Rails, no Capybara, no Puma, no database —
   passed **41/41, twice**: once plain, once with this harness's exact Chrome preferences and
   arguments. `spctl` does report `rejected` for the cached drivers, but that is expected for an
   ad-hoc/linker-signed binary and does not block execution: the driver runs and reports its version
   fine. No `com.apple.quarantine` is present, and no new driver is downloaded during a failing run
   (mtimes identical before and after).
5. **A shared `Selenium::WebDriver::Service`** (one chromedriver process instead of one per driver).
   Does not fix it — failed on the first run of four.

#### What is established

- **It is our harness, not the environment.** Bare Selenium cannot reproduce it; the Rails system
  suite reproduces it readily on the same machine, same Chrome, same driver, same options.
- **It is timing-sensitive, and instrumentation hides it.** Enabling chromedriver's own verbose
  logging gave **8 consecutive clean runs** where the baseline was ~1 in 3 — and the shared Service
  those runs also used was independently shown not to be the cause. This is the second time on this
  project that adding I/O latency has masked a system-test race (see the click-delivery entry below),
  so treat any "fix" that also adds a round trip with suspicion until it is A/B'd.

#### Where to look next

What differs between bare Selenium and the harness: Puma, the database, Capybara's session cache, and
**two things both managing the driver lifecycle** — Rails' own `SystemTestCase` teardown and this
project's added `driver.quit`. Since one failure appears to wedge the rest of the run, the question
worth answering first is what state survives a failed `create_session` and poisons the next one.

Instrument in a way that does not perturb timing — an in-memory record dumped at exit, rather than
per-launch logging.

**Do not** let it block a slice, and do not ship a mitigation that has not been A/B'd against a
baseline measured in the same session. Four hypotheses are closed above; this project has already
paid twice for shipping unproven ones.


#### The question as it stood

The plan gives Slice 5 a "15s delivery budget with the delivery-claim column + watchdog", and the
acceptance criterion is "translation-vs-timeout → exactly one delivery". That is unambiguous for
**WhatsApp**, where a message is genuinely *sent* once and cannot be taken back. It is not obvious
for the web chat, where nothing is sent at all: the message is written to the database and both
surfaces render whatever is there, live.

Today (end of Slice 4) a message is broadcast to the other party the instant it is created —
`Conversation#post_guest_message!` and `#post_staff_message!` both do it. So on the web there are two
coherent readings of "delivery":

1. **Hold the broadcast until the translation lands, or 15s, whichever comes first.** Matches the
   plan's wording literally. Costs a receptionist up to 15 seconds of not knowing a guest has
   written, in exchange for their first sight of it being in their own language.
2. **Broadcast immediately; the translation arrives later as an overlay and re-broadcasts.** The
   message appears at once in the sender's language and switches to the reader's a second later.
   Nothing is ever delayed, and the "exactly one delivery" race does not exist on this channel
   because nothing is irreversible.

**The recommendation, for whoever picks this up:** build (2) for the web and build the claim column
and watchdog anyway, unused on this channel, because Slice 6 needs them and building them against a
real second channel is when their semantics stop being guesswork. Say so explicitly in the code
rather than leaving a reader to wonder why a claim exists that nothing claims.

The argument for (2) is that a receptionist glancing at the inbox and seeing *nothing* for fifteen
seconds after a guest hit send is a worse failure than seeing the guest's own words for one second.
The argument against is that it means the inbox briefly shows text a Bosnian-only receptionist
cannot read — which is exactly what the chip solves, and which they would see anyway on every
fallback.

**Do not build both.** This is a product decision with a real trade-off, not a technical one, and it
is worth a human's thirty seconds before it becomes a week of behaviour.

---

### SOLVED: the system-test failure that made CI red on every run since the repo's first

**What it was:** Chrome's **breached-password check**. Every fixture signs in with `password123`,
which is one of the most-breached passwords in existence. Chrome submits it, matches it against
Google's breach corpus, and raises native "Change your password" UI — which takes the same input
grab the `<select>` popup does, and silently swallows every click and keystroke that follows.

**Why the symptom looked like a Chrome click bug:** the grab arrives *after* a successful sign-in
submit. So the first form submit in a session always worked and everything after it was dropped,
which reads exactly like "the pointer moved but the click never landed" — and that is what the
earlier diagnosis concluded, with real captured evidence that no request ever reached Rails. The
evidence was correct; the cause behind it was not.

**Why nobody found it in three sessions of local runs:** deciding whether a password is breached
needs a live call to Google. Anywhere the network is closed — an offline laptop, a sandbox, a
proxied container — the check never fires and the whole suite is green. It is not flaky. It is
100% deterministic, conditional on outbound network access.

**The fix** is four lines in `test/application_system_test_case.rb`: the
`profile.password_manager_leak_detection` preference plus the matching `PasswordLeakDetection`
feature flags. Confirmed by isolation — a run with only the leak-detection settings and nothing
else went green, so the keyring flags tried alongside them (`--password-store=basic`,
`--use-mock-keychain`) were cargo and were removed.

**Evidence:** run 31422526404 got past the system tests for the first time ever; run 31422934235,
with the leak-detection settings alone, was this repository's first fully green CI run.

**What this cost, and the lesson:** three sessions reported "tests green" from local runs while
every CI run had failed, back to the first commit. Because the job stopped at the system-test step,
`rubocop`, `brakeman` and `bundler-audit` had **never once executed** — and both rubocop and
brakeman had real findings waiting by the time anyone looked. A green local suite is not a green
build. Open the Actions tab.

**Do not** re-derive the old theory from the old symptom. The diagnosis document
([known-issue-system-test-flake.md](known-issue-system-test-flake.md)) is kept for its method, not
its conclusion.

<details>
<summary>The superseded diagnosis, kept for the record</summary>

### System-test flake: Chrome drops clicks (~4 runs in 10)

**Affects:** `test/system/platform_hotel_management_test.rb` only. No guest-facing test has ever been
observed failing from it.

**Mechanism (diagnosed, evidence in [known-issue-system-test-flake.md](known-issue-system-test-flake.md)):**
Chrome's WebDriver "Element Click" command intermittently moves the pointer without ever completing
the mousedown/mouseup. Captured directly: a capturing-phase `document` click listener recorded
nothing for the failing click, no `turbo:*` submit events fired, and the Rails log confirms no
request ever arrived — while Turbo's hover-triggered link-prefetch on a *neighbouring* link **did**
fire, proving the pointer moved but the click never landed. Not an app bug: nothing in `app/` or
`config/` is involved.

**A fix was proposed and rejected.** It measured 30% failures against a 40% baseline — within noise —
and its author stated they could not tell whether the retry logic or the incidental JavaScript round
trip it performed was doing the work. It had also escalated to five retry attempts, which would turn
a click that landed but was observed late into a five-fold repeated submit on any non-idempotent
form. The patch is preserved in the diagnosis document for whoever picks this up.

**If you take this on:** measure the baseline in the same session and under the same load as the fix.
Running the file 30 times back-to-back degrades the machine badly enough to produce failures with no
code change at all — that confound invalidated an earlier measurement.

**Do not** add mitigations for it in passing, and do not let it block a slice.

#### New evidence (Slice 2 Task 3 session) — this is why CI is red, and has been all along

**Every GitHub Actions run of this repo has failed**, back to the first one on 2026-08-07. Nobody had
looked: local runs were green and the handover reported those. The failing step is always
`bin/rails test:system`, and the failures are always the same three tests in
`platform_hotel_management_test.rb`, with the signature already diagnosed above — the form is still
on screen, unsubmitted, with no flash message. `bin/rails test` passes on CI (415/415 at the time of
writing).

Two consequences worth knowing:

- **The `rubocop` and `brakeman` steps have never run.** They come after `test:system` in
  `.github/workflows/ci.yml`, and the job stops at the first failure. Both had accumulated real
  findings by the time anyone checked; both are clean as of this session.
- The failure rate on the CI runner is **100%**, not the ~40% measured locally.

**A concrete difference from a passing local run, not yet tested as a fix:** CI's own log shows two
different Chromes on the runner. `browser-actions/setup-chrome@v1` reports
`Successfully setup chromium 151.0.7922.108`, and then the very next step, `google-chrome --version`,
prints **150.0.7871.128** — the version preinstalled on the runner image. Selenium Manager resolves a
chromedriver for whichever browser it detects, so the driver and the browser under test may not be
the pair anyone intended.

In this session's environment, Chrome 151.0.7922.108 driven by an exactly-matched chromedriver
151.0.7922.108 ran the full system suite **four consecutive times with zero failures**, this file
included. That is suggestive, not proof — a different machine and a different load, which is exactly
the confound that invalidated the earlier measurement. Whoever takes this on should pin the browser
and driver to the same build in CI and read the result, rather than adding retry logic to the app's
test harness.

**The failure is confined to this one file, confirmed on the runner itself.** A `workflow_dispatch`
run of the Slice 2 Task 3 branch (run 31418453644) executed 28 system tests and failed exactly 3 —
the same three, again. Every other test in the suite passed on CI, including that branch's new
two-browser live test, which drives two simultaneous Chrome sessions and is by far the most timing-
sensitive test in the repo. Whatever this is, it is not general flakiness in the harness.

**Postscript — the Chrome-version lead above was tested and is false.** Chrome 150.0.7871.128 with
an exactly-matched chromedriver ran the affected file clean twice locally, so the two-Chromes-on-the
-runner observation, while real, was not the cause. The actual cause is the password leak check, in
the section above.

</details>

---

## Unverified assumptions that need checking against reality

### Render's proxy address (check at first real deploy)

`config/environments/production.rb` sets `config.action_dispatch.trusted_proxies` to Rails' own
default list (loopback plus the RFC1918 private ranges), and `Rack::Attack::Request#trusted_proxy?`
follows that same config so every throttle resolves the real client IP consistently.

This is the standard PaaS assumption (it is how Heroku's routers present themselves to a dyno) but it
is **not yet verified against a live Render edge**. If Render's proxy presents from outside those
ranges, every guest collapses into a single throttle bucket — one abusive guest would 429 an entire
hotel, staff sign-ins included.

**To check:** log `request.remote_ip` and `REMOTE_ADDR` from a real deployed request. If they differ
from expectation, extend that one line in `production.rb`; nothing in `rack_attack.rb` needs to
change to pick it up.

### Translated copy is not native-speaker reviewed

The Bosnian, German and Arabic strings in `config/locales/guest.*.yml` are best-effort machine
translation. They are structurally protected (all four files must carry identical key sets and
interpolation variables) but nobody fluent has read them. Before a real pilot, have a native speaker
review at minimum the emergency-channel line and the privacy notice.

### Legal copy is a pilot draft

The privacy notice and terms are marked in-product as pending legal review. That marker is
test-protected so it cannot be removed silently. Do not ship to a real hotel without a lawyer.

---

## Deferred findings — reviewed, understood, judged not worth fixing yet

Hand these to the final whole-branch review before merge. **Do not fix them speculatively.**

| Finding | Why deferred |
|---|---|
| `guest_sessions.token_digest` index is not unique | Negligible with 256-bit random tokens; a DB constraint would only convert an already-impossible collision into a louder failure |
| `GuestLocaleHelper` region-tag boundary matching is untested at the edge | Low real-world impact; `Accept-Language` parsing is otherwise well covered |
| `phone_e164` has no format validation despite `phonelib` being a dependency | Belongs to Slice 6, where phone becomes the WhatsApp identity key and the validation actually matters |
| Guest session cookies never expire server-side (no `sessions.expires_at`) | Deliberate, documented in `app/controllers/concerns/authentication.rb`. Deactivating a user already destroys their live sessions, which covers the sharp edge. Doing it properly needs a migration, a check, and a sweep job — a real task, not a rider |
| `trusted_proxy?` would raise `NoMethodError` on a non-String argument | Unreachable: Rack's `#ip` only ever passes String or nil |
| Suspended-hotel page returns HTTP 200 rather than 503 | Consistent between the fresh-visitor and mid-stay flows; predates the current code |
| On a 429 the anthropic gem sleeps for the response's `retry-after` **unclamped**, inside a single `Ai::Client#chat` call | Only the gem's *own* exponential backoff is capped (`max_retry_delay`, 8s); a header-supplied delay is honoured in full, so a server asking for a long pause blocks the call for that long. Bounded in practice by `MAX_RETRIES = 1` (one sleep, not two) and by Solid Queue serializing the conversation, so the blast radius is one guest waiting. Fixing it properly means either `max_retries: 0` plus our own retry loop, or an SDK middleware that rewrites the header — both real tasks, and neither worth doing before we have seen a single 429 in production. **If you do see one:** check `AiRun` latency before assuming the model was slow |

---

## Claims that have been investigated and are FALSE — do not "fix" these

- **"Tailwind CSS is never linked because the layout uses `stylesheet_link_tag :app` instead of
  `:tailwind`."** False. Propshaft's bulk-inclusion means `:app` emits every compiled stylesheet
  including `tailwind-<digest>.css`. Verified against rendered output. A previous agent reported this
  as a defect; it is not one.

- **"The system-test flake is caused by parallel test workers."** False. Rails only parallelizes above
  a 50-test threshold and the affected file has four tests, so `PARALLEL_WORKERS=1` was a no-op — the
  apparent correlation was sampling noise. Rails prints `parallelization threshold is 50` on every
  run.

---

## Tooling note

Long-running review and implementation subagents on the largest model stalled repeatedly on this
project (four parallel agents, ~286k tokens, zero results). Mid-tier models have been reliable
throughout. If an agent hangs with no progress, switch tiers rather than retrying.
