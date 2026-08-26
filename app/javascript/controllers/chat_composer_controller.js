import { Controller } from "@hotwired/stimulus"

// Owns two small, CSP-mandated behaviours the composer and the
// quick-action chips both need (there is no inline <script> anywhere on
// the guest surface, so both live here as a Stimulus controller instead):
//
//   1. A tapped quick-action chip fills the composer's textarea with an
//      editable sentence — it never submits anything itself, so a request
//      the guest didn't read and confirm can never be sent.
//   2. The composer's own send states: clearing the textarea and minting a
//      fresh client_message_id after a successful send (server-side
//      idempotency — see Conversation#post_guest_message! — depends on
//      every real send carrying its own, never-reused id), and showing a
//      "couldn't send" notice on a genuine network failure without
//      clearing what the guest typed, so pressing Send again is the retry
//      affordance (safe to repeat: same client_message_id).
//
// Declared on a shared ancestor (chats/show.html.erb), not on the
// composer <form> itself, because the quick-action chips
// (guest/chats/_quick_actions.html.erb) are a sibling of the composer, not
// a descendant of it — both need to be inside the same controller's scope
// for a chip's click action to reach the composer's own targets.
export default class extends Controller {
  static targets = ["form", "input", "clientMessageId", "offlineNotice", "typingIndicator"]
  static values = { expectReply: Boolean }

  // How long the indicator may run before it gives up on its own.
  //
  // Ai::GenerateReplyJob allows the model 25s and retries once, and every
  // failure path past that posts a degraded notice — so a reply or an honest
  // "someone will get to this" should always arrive well inside this. The
  // timeout is not the mechanism, it is the backstop for the case the
  // mechanism cannot cover: a job that dies without running its own rescue,
  // where nothing will ever arrive to clear the indicator. Dots that animate
  // forever are a worse lie than no dots at all.
  static TYPING_TIMEOUT_MS = 75_000

  connect() {
    this.#resize()

    // The transcript is where every reply lands, from any source — the live
    // broadcast, the resilience layer's resync, a staff message. Watching it
    // means the indicator clears on whichever actually arrives, without this
    // controller needing to know which.
    //
    // But NOT on the guest's own message. Turbo appends that after
    // turbo:submit-end fires, so an observer that hides on any mutation hides
    // the indicator a few milliseconds after showing it — measured in a real
    // browser, it never became visible at all. The sender role is the only
    // thing that distinguishes "your message arrived" from "a reply arrived",
    // which is why _message.html.erb carries it.
    this.transcriptObserver = new MutationObserver((mutations) => {
      const reply = mutations.some((mutation) =>
        Array.from(mutation.addedNodes).some((node) =>
          node.nodeType === Node.ELEMENT_NODE &&
          node.dataset?.senderRole &&
          node.dataset.senderRole !== "guest"
        )
      )

      if (reply) {
        this.#hideTyping()
        return
      }

      // Not a reply, so it is the guest's own message, which Turbo appends to
      // the end of the transcript after turbo:submit-end — i.e. *below* the
      // indicator we just showed. Conversation#broadcast_new_message appends
      // to the same target, so anything arriving does the same. Put the dots
      // back at the bottom, where the answer they promise will actually land.
      if (this.#typingVisible()) this.#moveTypingToEnd()
    })
    this.transcriptObserver.observe(this.#transcript, { childList: true })
  }

  disconnect() {
    this.transcriptObserver?.disconnect()
    clearTimeout(this.typingTimeout)
  }

  fillFromChip(event) {
    this.inputTarget.value = event.currentTarget.dataset.prefillText
    this.#resize()
    // Focus last, and only after the textarea has been resized: focusing
    // first makes the browser scroll a one-line box into view and then grow
    // it underneath the guest, which reads as the page jumping. The cursor
    // goes to the end so the guest can keep typing rather than having to tap
    // again to get past the prefilled sentence.
    this.inputTarget.focus()
    this.inputTarget.setSelectionRange(this.inputTarget.value.length, this.inputTarget.value.length)
  }

  autoGrow() {
    this.#resize()
  }

  // One line is too little to compose a real request on a phone, and a fixed
  // taller box wastes transcript on every guest who only types "thanks". The
  // max height is enforced in CSS (max-h-32) so the transcript can never be
  // squeezed out entirely by a long message.
  #resize() {
    const input = this.inputTarget
    input.style.height = "auto"
    input.style.height = `${input.scrollHeight}px`
  }

  submitEnd(event) {
    this.offlineNoticeTarget.classList.add("hidden")

    if (event.detail.success) {
      this.inputTarget.value = ""
      this.#regenerateClientMessageId()
      this.#resize()
      this.#showTypingIfReplyExpected()
    }

    // Keeping focus keeps the keyboard up, which is what a guest sending a
    // second message wants — but only when the keyboard was already up.
    // Re-focusing on a phone the guest had put down would summon it uninvited
    // and scroll the transcript out from under them.
    if (document.activeElement === this.inputTarget || this.#keyboardLikelyOpen()) {
      this.inputTarget.focus()
    }
  }

  #keyboardLikelyOpen() {
    if (!window.visualViewport) return false

    return window.visualViewport.height < window.innerHeight - 120
  }

  // Turbo's own default handling for a failed fetch is meant for page
  // navigation, not a fragment update on a page the guest is actively
  // typing on — preventDefault keeps this a same-page notice instead.
  networkError(event) {
    event.preventDefault()
    this.offlineNoticeTarget.classList.remove("hidden")
    // The message never reached the server, so nothing is coming back.
    this.#hideTyping()
  }

  // Only when an answer is genuinely on its way. expectReply is false while
  // reception has taken the conversation over or the hotel has the assistant
  // switched off — a person will reply, in their own time, and dots implying
  // otherwise would be inventing activity that is not happening.
  #showTypingIfReplyExpected() {
    if (!this.expectReplyValue || !this.hasTypingIndicatorTarget) return

    this.#moveTypingToEnd()
    this.typingIndicatorTarget.classList.remove("hidden")
    this.typingIndicatorTarget.classList.add("flex")
    this.#scrollTranscriptToBottom()

    clearTimeout(this.typingTimeout)
    this.typingTimeout = setTimeout(() => this.#hideTyping(), this.constructor.TYPING_TIMEOUT_MS)
  }

  #typingVisible() {
    return this.hasTypingIndicatorTarget && !this.typingIndicatorTarget.classList.contains("hidden")
  }

  // The indicator has to be the last thing in the transcript, and it cannot
  // simply be rendered there once: every message that arrives — the guest's
  // own via Turbo, a reply or a staff message via broadcast_append_to — is
  // appended after it, pushing the dots above the newest message.
  //
  // The early return is not an optimisation. Moving the element is itself a
  // childList mutation, so it re-enters the observer above; without this the
  // two would call each other forever.
  #moveTypingToEnd() {
    const transcript = this.#transcript
    if (!transcript || !this.hasTypingIndicatorTarget) return
    if (transcript.lastElementChild === this.typingIndicatorTarget) return

    transcript.appendChild(this.typingIndicatorTarget)
  }

  #hideTyping() {
    clearTimeout(this.typingTimeout)
    if (!this.hasTypingIndicatorTarget) return

    this.typingIndicatorTarget.classList.add("hidden")
    this.typingIndicatorTarget.classList.remove("flex")
  }

  get #transcript() {
    return this.element.querySelector("#chat-messages")
  }

  // The indicator is the last thing in the transcript, so it is the thing a
  // guest needs to be able to see the moment it appears.
  #scrollTranscriptToBottom() {
    const transcript = this.#transcript
    if (transcript) transcript.scrollTop = transcript.scrollHeight
  }

  #regenerateClientMessageId() {
    this.clientMessageIdTarget.value = crypto.randomUUID()
  }
}
