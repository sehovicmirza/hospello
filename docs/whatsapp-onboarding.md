# WhatsApp channel — onboarding checklist

WhatsApp is a **second, optional** way for a guest to reach the same AI
concierge and reception dashboard the QR web chat already provides — it is
not a replacement for it, and it ships in a later slice (Slice 6) than
everything else in this repository today.

**The product is fully usable before WhatsApp is connected.** A hotel can
be onboarded, branded, staffed, and taking guest requests entirely through
its QR code with zero WhatsApp setup. Nothing about WhatsApp blocks a
pilot from starting. Treat this document as paperwork to start early
(day one, per the MVP plan) precisely because its lead times are the
longest-running thing on the critical path to using WhatsApp specifically
— not because a hotel needs it to go live at all.

This checklist separates three things that are easy to conflate and have
very different owners:

1. **What Hospello does** — engineering and integration work, on our
   timeline.
2. **What the hotel must provide** — decisions and assets only the hotel
   can supply.
3. **What is outside anyone's control** — Meta's own review processes, on
   Meta's timeline, which neither Hospello nor the hotel can expedite.

## 1. What Hospello does

- Builds against the **Meta Cloud API payload shape** behind an internal
  provider port (`Whatsapp::Provider`), so the specific BSP (Business
  Solution Provider) underneath can change without a rewrite.
- **Development starts immediately, today, against Meta's free test
  number** — no business verification, no display-name review, up to 5
  test recipient phone numbers. This is what Slice 6's engineering work is
  built and tested against before any hotel is involved.
- For a real hotel pilot, recommends and integrates with **360dialog** as
  the BSP: zero per-message markup, roughly **€49/month per number**,
  hosted Embedded Signup (a guided, in-browser flow the hotel completes
  themselves), and documented support for **Coexistence** — see below for
  why that specifically matters for the hotels we're targeting.
  - **Twilio** is the documented runner-up: faster developer experience,
    roughly **$0.005 per message** markup, and a different payload shape
    than Meta Cloud API (the provider port exists partly so this is a
    config/adapter change, not a rewrite, if we ever switch).
  - Going directly to Meta as the Tech Provider (no BSP) is a real option
    long-term, but requires **Hospello itself** — not each hotel — to pass
    Meta's App Review first. Not pursued for the pilot.
- Implements the webhook, signature verification, message normalization,
  and the 24-hour customer-service-window handling (see the runbook's
  WhatsApp placeholder section, filled in when this ships).
- Registers and tracks the approval status of the pre-approved message
  template(s) each hotel needs for the cases below.

## 2. What the hotel must provide

Collect these before starting a hotel's WhatsApp setup — nothing below can
be filled in on the hotel's behalf:

- **Legal/trading name** — used for Meta's business verification, if the
  hotel ever needs it (see the thresholds in section 3).
- **Display name** — what guests see as the sender name in WhatsApp. This
  goes through Meta's own review (see section 3) and has to plausibly match
  the hotel's real-world identity, or it gets rejected and has to be
  resubmitted.
- **A phone number, with a decision on which one.** The low-friction
  default we recommend is **Coexistence**: the hotel keeps using its
  existing number and the regular WhatsApp Business app on a phone at the
  front desk exactly as before, while that same number also gains Cloud
  API access for Hospello's automation. This matters specifically for the
  hotels we're onboarding first: small Bosnian hotels almost certainly
  already run the WhatsApp Business app on their main guest-facing number,
  and a "fresh number" migration would mean reprinting every piece of
  signage and asking existing guests to learn a new number — friction with
  no upside. A brand-new dedicated number is the fallback only when the
  hotel doesn't already have a number they want to keep using this way, or
  actively wants separation.
- **A Meta Business Portfolio** (formerly Business Manager) — the hotel's
  own Meta-side account that owns their WhatsApp Business Account (WABA).
  360dialog's hosted Embedded Signup walks the hotel through creating this
  if they don't already have one; it does not require deep technical
  knowledge, but it does require someone at the hotel with authority to
  represent the business to Meta (usually the owner or general manager,
  not front-desk staff).
- **An opt-in checkbox in their booking/check-in flow**, worded to name
  WhatsApp explicitly (e.g. "I agree to receive messages from [Hotel] via
  WhatsApp") — not a generic "contact me" checkbox. This is what makes it
  compliant to send that guest a business-initiated WhatsApp message later,
  and it's the hotel's flow to add, not something Hospello can insert into
  their check-in process.

## 3. What is outside anyone's control

These are Meta's own review and verification processes. Neither Hospello
nor the hotel can pay, escalate, or otherwise speed them up — budget the
time and set expectations with the hotel accordingly:

- **Display-name review** — typically **1–7 business days**. Meta checks
  that the requested display name plausibly represents the real business.
  A rejection requires resubmitting, restarting the clock.
- **Business verification** — typically **1 day to 2 weeks**, and only
  becomes necessary once a WABA sends more than **250 business-initiated
  conversations per day**. A 20-room pilot hotel will not approach that
  volume for months, if ever, at the message rates a concierge channel
  actually sees — so for the pilot, plan around display-name review as the
  real lead time, and treat business verification as a later-stage
  concern to revisit only if usage grows that far.
- **The 24-hour customer service window.** Once a guest messages the
  hotel's number, the hotel (via Hospello) can freely reply for 24 hours.
  Outside that window, a **business-initiated** message (the hotel or the
  concierge reaching out first — a booking confirmation, a proactive
  notice) requires a **pre-approved message template**, and template
  approval is itself a Meta review step with its own turnaround, separate
  from display-name review. Design any proactive-messaging feature around
  this constraint from the start rather than discovering it at launch.

## Sequencing recommendation

Given the above, the practical order for a given hotel is:

1. Collect the hotel-provided items in section 2 as early as possible —
   these have no external lead time, but everything in section 3 can't
   start until they're in hand.
2. Start display-name review and, if applicable down the line, business
   verification, in parallel with everything else — they run on Meta's
   clock regardless of what else is ready.
3. In the meantime, the hotel is already live on the QR web chat. WhatsApp
   activates as an additional channel once review clears; nothing about
   the hotel's existing service is blocked or paused while it's pending.
