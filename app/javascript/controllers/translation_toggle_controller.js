import { Controller } from "@hotwired/stimulus"

// Shows the original text behind a translation.
//
// Both halves are rendered server-side and one is hidden; this only swaps
// which. That matters more than it looks: it means the original is present in
// the DOM whether or not JavaScript ever runs, so a receptionist on a locked-
// down browser can still find what the guest actually wrote by selecting the
// page — and there is no inline script anywhere on either surface (the CSP
// forbids it), so a Stimulus controller is the only way to do this at all.
export default class extends Controller {
  static targets = ["translated", "original", "button"]
  static values = { showLabel: String, hideLabel: String }

  toggle() {
    const showingOriginal = this.originalTarget.hidden

    this.originalTarget.hidden = !showingOriginal
    this.translatedTarget.hidden = showingOriginal
    this.buttonTarget.textContent = showingOriginal ? this.hideLabelValue : this.showLabelValue
    this.buttonTarget.setAttribute("aria-expanded", String(showingOriginal))
  }
}
