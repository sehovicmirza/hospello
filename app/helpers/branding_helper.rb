module BrandingHelper
  # Tailwind's gray-900 and pure white — the two candidates we choose between
  # for text placed on a hotel's primary color. Not derived from the hotel's
  # own palette: WCAG contrast is about what reads clearly against the brand
  # color, not about matching it.
  ON_PRIMARY_DARK = "#111827"
  ON_PRIMARY_LIGHT = "#FFFFFF"

  # Hotel's own column defaults (db/schema.rb) — what a blank or malformed
  # color falls back to, so this helper never has to raise or trust unvalidated
  # input just because it ran ahead of Hotel's own format validation (see
  # #normalized_hex below).
  DEFAULT_PRIMARY_COLOR = "#1F3A5F"
  DEFAULT_SECONDARY_COLOR = "#C9A227"

  # CSS custom properties for a hotel's brand colors, ready to interpolate
  # straight into a style="" attribute, e.g.
  # `<body style="<%= hotel_brand_style(@hotel) %>">`. `--brand-on-primary`
  # is chosen by relative luminance (WCAG), not hardcoded, so a hotel that
  # picks a pale primary color still gets readable text on it instead of
  # white-on-white.
  #
  # Returns an HTML-safe string. Hotel validates primary_color/secondary_color
  # with Hotel::COLOR_FORMAT on every *save*, but this helper also renders on
  # Staff::HotelSettingsController's :edit template when a save just *failed*
  # — at that point @hotel carries whatever the admin typed, unsaved and
  # unvalidated, which is exactly the case a review found this raising
  # (nil/non-hex) or, worse, marking safe and interpolating verbatim (a value
  # shaped like six hex digits with a trailing quoted attribute survives the
  # length/charset check and breaks out of style=""). #normalized_hex is the
  # actual safety boundary — html_safe only describes its output, it doesn't
  # create it.
  def hotel_brand_style(hotel)
    primary = normalized_hex(hotel.primary_color, default: DEFAULT_PRIMARY_COLOR)
    secondary = normalized_hex(hotel.secondary_color, default: DEFAULT_SECONDARY_COLOR)

    properties = {
      "--brand-primary" => primary,
      "--brand-secondary" => secondary,
      "--brand-on-primary" => on_primary_color(primary)
    }

    properties.map { |property, value| "#{property}:#{value};" }.join.html_safe
  end

  # The colour the browser paints its own chrome with — Safari's top bar and
  # Chrome's address bar both read this.
  #
  # It is the closest thing there is to the "full screen" a QR-scanned page
  # cannot have: no browser will hide its address bar for a page it just
  # navigated to (that bar is how a guest can tell they are on the hotel's site
  # and not a copy of it), but it will colour it. Tinted with the hotel's own
  # primary, the bar stops reading as browser furniture sitting on top of the
  # chat and starts reading as the top of the hotel's app.
  def hotel_theme_color(hotel)
    normalized_hex(hotel.primary_color, default: DEFAULT_PRIMARY_COLOR)
  end

  private
    # Hotel::COLOR_FORMAT is anchored (\A...\z), so anything other than
    # exactly "#" + six hex digits — nil, "", "blue", or a well-formed prefix
    # with trailing garbage appended — fails the match and never reaches the
    # html_safe string. This is what makes marking the final string safe
    # correct rather than merely asserted.
    def normalized_hex(value, default:)
      Hotel::COLOR_FORMAT.match?(value.to_s) ? value : default
    end

    def on_primary_color(primary_hex)
      primary_luminance = relative_luminance(primary_hex)
      dark_contrast = contrast_ratio(primary_luminance, relative_luminance(ON_PRIMARY_DARK))
      light_contrast = contrast_ratio(primary_luminance, relative_luminance(ON_PRIMARY_LIGHT))

      dark_contrast >= light_contrast ? ON_PRIMARY_DARK : ON_PRIMARY_LIGHT
    end

    # WCAG 2.x contrast ratio between two relative luminances.
    # https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio
    def contrast_ratio(luminance_a, luminance_b)
      lighter, darker = [ luminance_a, luminance_b ].max, [ luminance_a, luminance_b ].min
      (lighter + 0.05) / (darker + 0.05)
    end

    # WCAG 2.x relative luminance of an sRGB color.
    # https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
    def relative_luminance(hex_color)
      r, g, b = hex_color.delete("#").scan(/\h\h/).map { |channel| linearize(channel.to_i(16) / 255.0) }
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end

    def linearize(channel)
      channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055)**2.4
    end
end
