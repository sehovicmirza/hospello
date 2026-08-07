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

  // WCAG 2.x relative luminance and contrast ratio — kept in sync by hand
  // with BrandingHelper#hotel_brand_style since this runs in the browser.
  // Deliberately computes both candidates' actual contrast ratios and takes
  // the higher one, rather than comparing against a fixed luminance
  // threshold: a threshold derived for literal black vs white picks the
  // lower-contrast candidate for real colors in the gap between the dark
  // candidate's true crossover and black's (e.g. #767676) — see
  // BrandingHelper for the worked example that review round 1 found.
  #onPrimaryColor(hex) {
    if (!/^#[0-9A-Fa-f]{6}$/.test(hex)) return "#111827"

    const luminance = (color) => {
      const channel = (start) => {
        const value = parseInt(color.slice(start, start + 2), 16) / 255
        return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
      }
      return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5)
    }

    const contrastRatio = (luminanceA, luminanceB) =>
      (Math.max(luminanceA, luminanceB) + 0.05) / (Math.min(luminanceA, luminanceB) + 0.05)

    const primaryLuminance = luminance(hex)
    const darkContrast = contrastRatio(primaryLuminance, luminance("#111827"))
    const lightContrast = contrastRatio(primaryLuminance, luminance("#ffffff"))

    return darkContrast >= lightContrast ? "#111827" : "#FFFFFF"
  }
}
