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

    this.observer = new MutationObserver(() => this.#handleNewMessages())
    this.observer.observe(this.messagesTarget, { childList: true })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  #handleNewMessages() {
    if (this.#isNearBottom()) this.#scrollToBottom()
  }

  #isNearBottom() {
    const el = this.messagesTarget
    return el.scrollHeight - el.scrollTop - el.clientHeight <= this.constructor.NEAR_BOTTOM_PX
  }

  #scrollToBottom() {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
  }
}
