# Known issues, unverified assumptions, and deferred findings

Check here before "fixing" something. Several entries below look like bugs and are deliberate; one
looks like a passing test and is a hole.

---

## Open

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
