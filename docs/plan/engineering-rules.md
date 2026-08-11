# Engineering rules

Every rule here was paid for with a real defect in this codebase. None of them are style preferences.
They bind every task in every slice.

---

## 1. Write assertions that can fail

This is the dominant defect in this project — **more than twenty instances across the first two
slices**, more than every other category combined. The recurring shapes:

- `assert_match "2", response.body` — substring matching against a whole page. Every digit and most
  short words appear somewhere in a Tailwind class name. Scope to a row (`within`, `assert_select`).
- Asserting a value that equals the column default, so the test passes even if the attribute was
  never assigned. Invert the default in the test data.
- Asserting on a variable a `setup` block already set to the expected value.
- Asserting an attribute is *present* rather than that the behaviour happens. `dir="rtl"` being in
  the markup is not a claim that anything reads right-to-left.

A QR code in this repo could once have encoded a completely wrong URL with all 22 of its tests
green. A guest session could be created for the wrong hotel with the isolation suite passing.

**For anything guarding a security, tenancy, or money boundary: break the code, watch the test fail,
put it back.** A test that cannot fail is worse than no test, because it advertises coverage that
isn't there.

## 2. Copy the spec demands needs a test — and the test must not read the same source the app reads

Nine guest-facing requirements once shipped with zero protection: the "not an emergency channel"
notice, the privacy notice and its pending-legal-review marker, the `powered_by_visible` toggle,
language preselection, and the entire Arabic locale file could each be **deleted outright** with the
full suite staying green.

Two traps, both of which produced a passing test over broken code here:

- **Fallbacks absorb the failure.** With `config.i18n.fallbacks = true`, emptying a locale file
  renders English and nothing notices. Read locale files **off disk** and compare key sets and
  `%{interpolation}` variables structurally between languages, rather than going through `I18n.t`.
- **Deriving the expected value from the source under test is circular.** `assert_text
  I18n.t("guest.emergency_notice")` passes no matter what that key contains, including nothing.
  Paste the literal string into the test.

For direction-aware layout, pin the logical utility class against its physical counterpart
(`test/controllers/staff/qr_codes_controller_test.rb`) **and** measure real geometry with
`getBoundingClientRect` (`test/system/qr_download_test.rb`). Both patterns already exist — copy them
rather than inventing a third.

## 3. Guard the idiomatic way in, not just the obvious one

A guard that covers the obvious path and misses the idiomatic one is worth roughly nothing. Two real
examples from one review round:

- A `before_validation` guard protected `update` but not `update_attribute`, which calls
  `save(validate: false)` and skips validation callbacks entirely — so the one write that *reads*
  like a safe single-field update was the one that got through. `before_save` covers both.
- A grep tripwire for raw SQL required a literal dot before `connection`, catching
  `ActiveRecord::Base.connection.execute(...)` and sailing past bare `connection.execute(...)` — the
  implicit-receiver form, which inside a model is the *more* likely one to be written.

When you write a guard, list the ways in and check each.

## 4. Assert on the destination after a click that navigates

`click_on` returns when the click is dispatched, not when the resulting page has loaded. A
`click_on "Sign in"` followed by `visit` once raced the sign-in response and left the session cookie
unset, surfacing much later as a missing form field. One `assert_text` on the destination makes the
click and its navigation a single step.

## 5. System tests: keep each one short and single-purpose

Chrome does not release the input grab a native `<select>` popup takes when the page navigates while
that popup is open, and Rails reuses one browser process across the whole run, so a poisoned session
breaks whichever test runs next. The harness (`test/application_system_test_case.rb`) carries three
deliberate mitigations — blurring after `select`, quitting the driver between tests, and teaching
Capybara Chrome's second spelling of a detached-node error. **Do not remove or duplicate them.**

Still: prefer several focused tests over one long ceremony. Set preconditions up directly in Ruby and
drive only the behaviour under test through the browser.

## 6. Don't add a workaround for a failure you haven't diagnosed — and don't ship a mitigation you haven't proven

Two wrong theories (Turbo, then a Selenium version mismatch) once produced five permanent changes
across the harness and three views, **including a production behaviour change**, none of which
addressed the real cause. The real cause was found by bisection in twenty minutes once someone
actually looked.

The corollary matters just as much: a later proposed fix for a different flake was **rejected**
because its author could not show it worked — the measured improvement was within noise of the
baseline, and they could not separate their fix's logic from the observer effect of the extra
JavaScript round trip it performed. See [known-issues.md](known-issues.md).

If a test fails for a reason you can't explain, **say so in your report** rather than sprinkling
mitigations. An honest open issue is worth more than a confident wrong fix.

## 7. Tenancy is absolute, and it fails closed

`acts_as_tenant` runs with `require_tenant = true`, so an unscoped query **raises** rather than
returning every hotel's rows. Do not defeat this. The escape hatches (`without_tenant`, `unscoped`,
`default_tenant =`, `find_by_sql`, raw `connection.execute`) are grep-tested by
`test/tenancy/without_tenant_grep_test.rb` and allowed **only** in `app/controllers/platform/`, plus
two narrowly allow-listed calls, both of the same shape — a lookup whose *result* is what decides the
tenant, so it cannot itself run inside one:

- `GuestSession.authenticate_by_token` — a guest's cookie carries no hotel context.
- `WhatsappChannel.route` — an inbound webhook carries only Meta's `phone_number_id`, and that is
  what picks the hotel. Safe additionally because `phone_number_id` is globally unique, so exactly
  one row can come back.

Both use `find_by_sql`, which never touches `default_scope` at all, so it needs no escape hatch and
sets no tenant anywhere. Neither is a licence for a general cross-tenant query.

If you genuinely need a new exception, add it to the allowlist **narrowly** — by that specific
pattern at that specific path — and explain why in a comment. Never widen the allowlist to a whole
file.

## 8. Product invariants that are not negotiable

These come from the spec and several are load-bearing for trust, not just correctness:

- **Guest identity is always unverified.** The room number is self-entered on a shared QR code. Staff
  see an UNVERIFIED badge. It is never used to reveal sensitive data.
- **The AI may gather and propose; only a human may confirm.** Exactly one service request per
  confirmed ask. Nothing is ever described to a guest as confirmed, booked, or approved before staff
  act on it.
- **The AI answers only from that hotel's published knowledge base.** It never invents prices, hours,
  or availability. When it doesn't know, it says so and hands off.
- **Originals are immutable; translations are overlays.** Numbers, times and names are never silently
  altered — there is a mechanical digit guard for this.
- **No dead ends.** Every failure state tells the guest what to do next. The chat is not an emergency
  channel and says so.
- **Data belonging to one hotel is never visible to, or used when answering for, another.**
