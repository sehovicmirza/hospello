# WhatsApp channel — onboarding checklist

WhatsApp is a **second, optional** way for a guest to reach the same AI
concierge and reception dashboard the QR web chat already provides — it is
not a replacement for it.

**Status: built.** A guest can message a hotel's number, be asked for their
room and name, get answers from that hotel's knowledge base, and take a
request through the same confirm-before-create flow — all of it landing in
the same reception inbox. Section 4 below is the part that turns that from
"works in the test suite" into "works for a real hotel", and it is the
section to read first if you have a number in hand.

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
  and the 24-hour customer-service-window handling. **All built** — the
  window is enforced inside the provider itself (`Whatsapp::Provider`), so
  no caller can forget it, and a send outside the window marks the message
  undelivered on the reception transcript with a sentence saying why.
- Provides the screen where a hotel records its number and reads its state
  (**Staff → WhatsApp**), and the registry where it records which message
  templates Meta has approved. Nothing about connecting a number needs an
  engineer or a Rails console.

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

## 4. Connecting a number — the actual steps

Everything above is about lead times. This is the part someone does with a
number already in hand, and it is the same short list whether the number is
Meta's free test number or a hotel's real one.

**Meta's free test number needs none of section 3.** No business
verification, no display-name review, up to five test recipients you nominate
in the WhatsApp Manager. It is the right way to prove an environment works
end to end before a real hotel is involved.

### 4.1 On the server (once per environment)

Three secrets, all in `render.yaml` and all `sync: false` (so they are set in
Render's dashboard, never committed):

| Variable | Where it comes from |
|---|---|
| `WHATSAPP_ACCESS_TOKEN` | WhatsApp Manager → the System User token. Authorizes every send. |
| `WHATSAPP_APP_SECRET` | Meta App dashboard → App Settings → Basic. Verifies the signature on every delivery. |
| `WHATSAPP_WEBHOOK_VERIFY_TOKEN` | **You choose this.** Any random string; you type the same one into Meta below. |

`WHATSAPP_API_VERSION` has a default and only needs setting to pin or roll
forward.

**None of them is required for the app to run.** Every hotel's QR web chat
works with all three unset — WhatsApp is what stops working, and it stops
visibly: a send raises a named error and the message is marked undelivered on
the transcript, and an unsigned webhook is refused rather than trusted.

### 4.2 In Meta's App dashboard (once per environment)

Under **WhatsApp → Configuration → Webhook**:

- **Callback URL**: `https://<your-host>/webhooks/whatsapp`
- **Verify token**: the same string you set as `WHATSAPP_WEBHOOK_VERIFY_TOKEN`
- **Subscribe to**: the `messages` field. That single field carries both
  inbound guest messages and delivery receipts.

Meta sends a one-off `GET` handshake the moment you click Verify. If it fails,
the verify token does not match — nothing else produces that error.

### 4.3 In Hospello, per hotel (Staff → WhatsApp)

- **Phone number** — the displayed number, in full international form.
- **Phone number ID** — Meta's own id for that number, from the WhatsApp
  Manager. **This is not the phone number**, and it is the field worth
  double-checking: it is what routes an incoming message to a hotel, so a
  wrong value means guest messages arrive and reach nobody. It is globally
  unique, so another hotel's value is refused outright.
- **Status → Live.** A number left `Not confirmed yet` still receives
  messages (that is how you confirm it works) but is not offered to guests on
  the landing page — the "Chat on WhatsApp" button appears only for a live
  number, because a button leading to a number nobody answers is worse than
  no button.

### 4.4 Confirming it actually works

In order, because each step tells you something the next one assumes:

1. **Message the number from a phone.** Within a second or two the
   conversation appears in the reception inbox, badged WhatsApp.
2. **Check Staff → WhatsApp.** "Last message received" should now say
   *moments ago*. If the inbox is empty and this still says *Nothing has
   arrived yet*, the delivery never routed — the phone number ID is the first
   thing to re-check.
3. **Watch the concierge ask for the room and name**, in the language the
   guest wrote in. That is the first outbound send, so it also proves the
   access token.
4. **Reply from the reception inbox.** It arrives on the phone. If it is
   marked undelivered instead, read the line under it — the common case is the
   24-hour window, which reopens the moment the guest writes again.

### 4.5 Templates

A hotel may only write freely within 24 hours of the guest's last message.
Outside it, only a template Meta has already approved may be sent.

Templates are created and approved in **Meta's own Business Manager** —
nothing in Hospello submits one. The registry on the WhatsApp screen is where
a hotel records what it registered and what Meta said, so anyone at the hotel
can see whether the welcome message is usable yet without logging in there.

Two things worth knowing before designing anything around them:

- A template is identified by **name *and* language**. "welcome" in Bosnian
  and "welcome" in German are two separately-approved objects.
- The category is not cosmetic. A **utility** template (a booking
  confirmation, a service update) is judged far more leniently than a
  **marketing** one, and a marketing template sent to someone who did not
  explicitly opt in is what actually gets a number restricted. The welcome
  message is utility.

**There is deliberately no bulk-send screen**, and adding one is not a small
feature. An un-opted-in send risks the hotel's number, which is the hotel's
asset and not ours; the opt-in has to be collected at check-in with a
checkbox that names WhatsApp explicitly.

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
