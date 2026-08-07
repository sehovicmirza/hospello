module BrandingHelper
  # Tailwind's gray-900 and pure white — the two candidates we choose between
  # for text placed on a hotel's primary color. Not derived from the hotel's
  # own palette: WCAG contrast is about what reads clearly against the brand
  # color, not about matching it.
  ON_PRIMARY_DARK = "#111827"
  ON_PRIMARY_LIGHT = "#FFFFFF"

  # The relative luminance at which black and white text have equal contrast
  # against a background of that luminance. Solving the WCAG contrast-ratio
  # formula (L_light + 0.05) / (L_dark + 0.05) for white text (luminance 1)
  # against black text (luminance 0) — i.e. 1.05 / (L + 0.05) = (L + 0.05) /
  # 0.05 — yields L ≈ 0.179. Above that luminance dark text has the higher
  # contrast ratio; at or below it, light text does. Using this derived
  # crossover (rather than a flat 0.5 split on luminance) is what keeps a
  # pale — not just white — brand color from producing hard-to-read text.
  CONTRAST_CROSSOVER_LUMINANCE = 0.179

  # CSS custom properties for a hotel's brand colors, ready to interpolate
  # straight into a style="" attribute, e.g.
  # `<body style="<%= hotel_brand_style(@hotel) %>">`. `--brand-on-primary`
  # is chosen by relative luminance (WCAG), not hardcoded, so a hotel that
  # picks a pale primary color still gets readable text on it instead of
  # white-on-white.
  def hotel_brand_style(hotel)
    properties = {
      "--brand-primary" => hotel.primary_color,
      "--brand-secondary" => hotel.secondary_color,
      "--brand-on-primary" => on_primary_color(hotel.primary_color)
    }

    properties.map { |property, value| "#{property}:#{value};" }.join
  end

  private
    def on_primary_color(primary_hex)
      relative_luminance(primary_hex) > CONTRAST_CROSSOVER_LUMINANCE ? ON_PRIMARY_DARK : ON_PRIMARY_LIGHT
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
