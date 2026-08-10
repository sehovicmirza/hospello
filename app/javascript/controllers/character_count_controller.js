import { Controller } from "@hotwired/stimulus"

// A live count against KbEntry::MAX_CONTENT_LENGTH. The textarea's own
// maxlength already stops the overflow; this exists so someone writing
// their longest topic can see the ceiling coming, rather than meeting it
// as a silently-truncated paste. The server-side validation
// (KbEntry) is still the thing that decides — this is a courtesy.
export default class extends Controller {
  static targets = ["input", "output"]

  connect() {
    this.update()
  }

  update() {
    if (!this.hasInputTarget || !this.hasOutputTarget) return

    this.outputTarget.textContent = this.inputTarget.value.length
  }
}
