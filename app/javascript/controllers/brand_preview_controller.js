import { Controller } from "@hotwired/stimulus"

// Live-updates the guest-landing-header mock on the hotel settings page as
// the admin edits the color fields and logo, so "what will guests see"
// never lags behind the form. CSS custom properties on the preview target
// only — no canvas, no dependencies. The on-primary text color is chosen by
// the same WCAG relative-luminance formula as BrandingHelper#hotel_brand_style,
// so the preview never shows a combination the saved page wouldn't.
export default class extends Controller {
  static targets = [
    "preview",
    "primaryInput", "secondaryInput",
    "primarySwatch", "secondarySwatch",
    "logoInput", "logoPreview"
  ]

  connect() {
    this.update()
  }

  update() {
    const primary = this.primaryInputTarget.value
    const secondary = this.secondaryInputTarget.value

    this.previewTarget.style.setProperty("--brand-primary", primary)
    this.previewTarget.style.setProperty("--brand-secondary", secondary)
    this.previewTarget.style.setProperty("--brand-on-primary", this.#onPrimaryColor(primary))

    this.primarySwatchTarget.style.backgroundColor = primary
    this.secondarySwatchTarget.style.backgroundColor = secondary
  }

  updateLogo() {
    const file = this.logoInputTarget.files[0]
    if (!file) return

    const reader = new FileReader()
    reader.onload = () => {
      this.logoPreviewTarget.src = reader.result
      this.logoPreviewTarget.classList.remove("hidden")
    }
    reader.readAsDataURL(file)
  }

  // WCAG 2.x relative luminance — see BrandingHelper for the derivation of
  // the 0.179 crossover, kept in sync by hand since this runs in the browser.
  #onPrimaryColor(hex) {
    if (!/^#[0-9A-Fa-f]{6}$/.test(hex)) return "#111827"

    const channel = (start) => {
      const value = parseInt(hex.slice(start, start + 2), 16) / 255
      return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
    }

    const luminance = 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5)
    return luminance > 0.179 ? "#111827" : "#FFFFFF"
  }
}
