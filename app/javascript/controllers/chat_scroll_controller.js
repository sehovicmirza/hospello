import { Controller } from "@hotwired/stimulus"

// Keeps the transcript scrolled to the newest message as new ones arrive
// — from any of the three sources a message can appear from (the guest's
// own send, the live broadcast, or the resilience layer's resync fetch —
// see chat_resilience_controller.js): all three append into the same
// #chat-messages element, so one MutationObserver on childList covers
// all of them without needing to know which one fired.
export default class extends Controller {
  static targets = ["messages"]

  // How close to the bottom (in pixels) still counts as "at the bottom."
  // A guest who scrolled up to reread an earlier message must not get
  // yanked back down by a new one arriving elsewhere in the transcript.
  static NEAR_BOTTOM_PX = 48

  connect() {
    this.#scrollToBottom()

    this.observer = new MutationObserver((mutations) => this.#handleNewMessages(mutations))
    this.observer.observe(this.messagesTarget, { childList: true })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  // Whether the guest was at the bottom *before* this arrived, which is the
  // only version of the question worth asking.
  //
  // A MutationObserver callback runs after the DOM has already changed, so
  // asking #isNearBottom() here measures the distance with the new message
  // already in place — the transcript is further from the bottom by exactly the
  // height of the thing that just landed. Any reply taller than NEAR_BOTTOM_PX
  // therefore looked identical to a guest who had scrolled away to reread
  // something, and the follow was declined: the guest watched the typing dots,
  // then got an answer half of which was behind the composer, and had to scroll
  // to read a reply they had been waiting for.
  //
  // Subtracting what was just added reconstructs where they were, synchronously
  // and from the mutation itself. An earlier attempt recorded the position from
  // the scroll event instead; that event is asynchronous, so a guest who
  // scrolled up and received a message in the same tick was still yanked back —
  // caught by the "not yanked back down" test, which is why it exists.
  #handleNewMessages(mutations) {
    const el = this.messagesTarget
    const gap = parseFloat(getComputedStyle(el).rowGap) || 0
    const grew = mutations
      .flatMap((mutation) => Array.from(mutation.addedNodes))
      .filter((node) => node.nodeType === Node.ELEMENT_NODE)
      .reduce((total, node) => total + node.offsetHeight + gap, 0)

    const distanceNow = el.scrollHeight - el.scrollTop - el.clientHeight

    if (distanceNow - grew <= this.constructor.NEAR_BOTTOM_PX) this.#scrollToBottom()
  }

  #isNearBottom() {
    const el = this.messagesTarget
    return el.scrollHeight - el.scrollTop - el.clientHeight <= this.constructor.NEAR_BOTTOM_PX
  }

  #scrollToBottom() {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
  }
}
