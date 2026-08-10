import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// The staff-side mirror of chat_resilience_controller.js, encoding the same
// rule from the other end: the database is the source of truth and the
// live broadcast is only ever an enhancement on top of it. A receptionist's
// tablet sleeps, a hotel's wifi drops, a laptop lid closes — and when it
// comes back the inbox must already be right, not right-eventually.
//
// Where the guest side resyncs by fetching messages after an id, this one
// re-visits the current page: a refresh broadcast to [hotel, :inbox]
// (Conversation#broadcast_new_message) is what the server sends, and both
// the inbox list and the conversation detail view respond to it by
// re-rendering themselves from the server. That is also what keeps every
// count on those screens server-computed — there is nothing here that
// increments a badge locally, on purpose, so no badge can drift.
//
// Three triggers, matching the three things that actually happen to a
// front-desk machine:
//
//   1. Action Cable disconnect  — starts refreshing every 60s while down.
//   2. Action Cable reconnect   — one immediate refresh, then polling stops.
//   3. visibilitychange         — the tab-was-in-the-background case, which
//                                 covers a sleeping machine whether or not
//                                 the cable connection ever noticed.
//
// 60s rather than the guest side's 20s: a receptionist watching a screen
// tolerates a slower fallback than a guest waiting on a reply, and this
// poll re-renders a whole page rather than fetching a short message list.
export default class extends Controller {
  static targets = ["source", "offlineBanner"]

  static POLL_INTERVAL_MS = 60000

  connect() {
    this.pollTimer = null

    if (this.hasSourceTarget) {
      this.sourceObserver = new MutationObserver(() => this.#handleConnectionChange())
      this.sourceObserver.observe(this.sourceTarget, { attributes: true, attributeFilter: ["connected"] })
    }

    this.boundVisibilityChange = () => {
      if (!document.hidden) this.#refresh()
    }
    document.addEventListener("visibilitychange", this.boundVisibilityChange)

    this.boundOnline = () => this.#handleConnectionChange()
    this.boundOffline = () => this.#updateOfflineBanner()
    window.addEventListener("online", this.boundOnline)
    window.addEventListener("offline", this.boundOffline)

    this.#handleConnectionChange()
  }

  disconnect() {
    this.sourceObserver?.disconnect()
    document.removeEventListener("visibilitychange", this.boundVisibilityChange)
    window.removeEventListener("online", this.boundOnline)
    window.removeEventListener("offline", this.boundOffline)
    this.#stopPolling()
  }

  #handleConnectionChange() {
    if (this.#cableConnected) {
      this.#stopPolling()
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
    this.pollTimer = window.setInterval(() => this.#refresh(), this.constructor.POLL_INTERVAL_MS)
  }

  #stopPolling() {
    if (!this.pollTimer) return
    window.clearInterval(this.pollTimer)
    this.pollTimer = null
  }

  // action: "replace" against the current URL is what makes Turbo treat
  // this as a page refresh and therefore morph rather than swap — which is
  // what preserves the composer's half-typed reply (data-turbo-permanent in
  // staff/conversations/_composer.html.erb) and the reader's scroll
  // position. A plain visit would throw both away every minute.
  #refresh() {
    Turbo.visit(window.location.href, { action: "replace" })
  }
}
