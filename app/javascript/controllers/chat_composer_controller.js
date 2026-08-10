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
  static targets = ["form", "input", "clientMessageId", "offlineNotice"]

  fillFromChip(event) {
    this.inputTarget.value = event.currentTarget.dataset.prefillText
    this.inputTarget.focus()
  }

  submitEnd(event) {
    this.offlineNoticeTarget.classList.add("hidden")

    if (event.detail.success) {
      this.inputTarget.value = ""
      this.#regenerateClientMessageId()
    }

    this.inputTarget.focus()
  }

  // Turbo's own default handling for a failed fetch is meant for page
  // navigation, not a fragment update on a page the guest is actively
  // typing on — preventDefault keeps this a same-page notice instead.
  networkError(event) {
    event.preventDefault()
    this.offlineNoticeTarget.classList.remove("hidden")
  }

  #regenerateClientMessageId() {
    this.clientMessageIdTarget.value = crypto.randomUUID()
  }
}
