import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// The rule this encodes: the database is the source of truth and the live
// ActionCable broadcast (Conversation#post_guest_message!/#post_staff_message!)
// is only ever an enhancement on top of it — a dropped broadcast costs one
// poll interval, never a lost message. Triggers a GET
// /guest/messages?after=<last rendered id> (the resync endpoint,
// Guest::MessagesController#index) on the three events a guest's phone
// actually produces in practice:
//
//   1. Action Cable disconnect  — starts polling every 20s while down.
//   2. Action Cable reconnect   — one immediate resync, then polling stops.
//   3. visibilitychange         — the phone-unlocked-after-ten-minutes case,
//                                 the single most common real-world cable
//                                 killer, covered regardless of whether the
//                                 cable connection itself ever noticed
//                                 anything was wrong.
export default class extends Controller {
  static targets = ["messages", "source", "offlineBanner"]
  static values = { afterUrl: String, lastId: Number }

  static POLL_INTERVAL_MS = 20000

  connect() {
    this.pollTimer = null

    this.messagesObserver = new MutationObserver(() => this.#updateLastIdFromDom())
    this.messagesObserver.observe(this.messagesTarget, { childList: true })

    if (this.hasSourceTarget) {
      this.sourceObserver = new MutationObserver(() => this.#handleConnectionChange())
      this.sourceObserver.observe(this.sourceTarget, { attributes: true, attributeFilter: [ "connected" ] })
    }

    this.boundVisibilityChange = () => this.#resync()
    document.addEventListener("visibilitychange", this.boundVisibilityChange)

    this.boundOnline = () => this.#handleOnline()
    this.boundOffline = () => this.#updateOfflineBanner()
    window.addEventListener("online", this.boundOnline)
    window.addEventListener("offline", this.boundOffline)

    this.#handleConnectionChange()
  }

  disconnect() {
    this.messagesObserver?.disconnect()
    this.sourceObserver?.disconnect()
    document.removeEventListener("visibilitychange", this.boundVisibilityChange)
    window.removeEventListener("online", this.boundOnline)
    window.removeEventListener("offline", this.boundOffline)
    this.#stopPolling()
  }

  #handleOnline() {
    this.#resync()
    this.#updateOfflineBanner()
  }

  #handleConnectionChange() {
    if (this.#cableConnected) {
      this.#stopPolling()
      this.#resync()
    } else {
      this.#startPolling()
    }

    this.#updateOfflineBanner()
  }

  get #cableConnected() {
    return this.hasSourceTarget && this.sourceTarget.hasAttribute("connected")
  }

  #updateOfflineBanner() {
    if (!this.hasOfflineBannerTarget) return

    const shouldShow = !navigator.onLine || !this.#cableConnected
    this.offlineBannerTarget.classList.toggle("hidden", !shouldShow)
  }

  #startPolling() {
    if (this.pollTimer) return
    this.pollTimer = window.setInterval(() => this.#resync(), this.constructor.POLL_INTERVAL_MS)
  }

  #stopPolling() {
    if (!this.pollTimer) return
    window.clearInterval(this.pollTimer)
    this.pollTimer = null
  }

  async #resync() {
    let response
    try {
      response = await fetch(`${this.afterUrlValue}?after=${this.lastIdValue}`, {
        headers: { Accept: "text/vnd.turbo-stream.html" }
      })
    } catch (error) {
      // Offline or unreachable — the next poll tick or the next reconnect
      // tries again. Nothing lost: the database still has everything.
      return
    }

    if (!response.ok) return

    const html = await response.text()
    if (html.trim().length > 0) Turbo.renderStreamMessage(html)
  }

  #updateLastIdFromDom() {
    const last = this.messagesTarget.lastElementChild
    if (!last) return

    const id = Number(last.dataset.messageId)
    if (Number.isFinite(id) && id > this.lastIdValue) this.lastIdValue = id
  }
}
