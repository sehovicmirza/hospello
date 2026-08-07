# Be sure to restart your server when you modify this file.
#
# Verified against the actual pages most likely to break under a real
# policy, not assumed to work: the QR print sheet (a page-specific inline
# <style> block, app/views/staff/qr_codes/print.html.erb) and the branded
# staff screens (hotel-chosen colors written as inline style="" attributes,
# app/helpers/branding_helper.rb and app/views/staff/hotel_settings/edit.html.erb)
# — see test/system/content_security_policy_test.rb, which drives a real
# headless Chrome against this exact header.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    policy.script_src  :self

    # 'unsafe-inline' here is a deliberate, narrow compromise, not an
    # oversight: a hotel's primary/secondary color is rendered as an inline
    # style="" attribute (BrandingHelper#hotel_brand_style, the color
    # swatches and preview target on the hotel settings page) so it can vary
    # per hotel and update live via Stimulus, and CSP has no nonce mechanism
    # for style *attributes* — nonces only apply to <style> and <link>
    # *elements*. The same applies to the QR print sheet's page-specific
    # <style> block. The values reaching those attributes are hex colors
    # Hotel validates against COLOR_FORMAT (#RRGGBB, nothing else can reach
    # the attribute — see BrandingHelper's normalized_hex), so the practical
    # risk this concedes is narrow. script-src is deliberately NOT given the
    # same allowance — see below.
    policy.style_src :self, :unsafe_inline
  end

  # Nonces are scoped to script-src only, on purpose. importmap-rails
  # automatically stamps a nonce onto the inline <script type="importmap">
  # and <script type="module"> tags javascript_importmap_tags renders (see
  # every layout in app/views/layouts/) whenever a directive it targets is
  # nonce-enabled, so this is what makes those tags run under a strict
  # script-src with no 'unsafe-inline' at all.
  #
  # style-src is deliberately EXCLUDED from this list. CSP's own
  # backwards-compat rule is that once a directive carries a nonce-source, a
  # browser that understands nonces stops honoring 'unsafe-inline' for that
  # same directive — it's meant to let CSP2+ browsers ignore 'unsafe-inline'
  # in favor of the stronger nonce, while CSP1-only browsers (which don't
  # understand nonces) fall back to it. Every browser Hospello supports
  # understands nonces (`allow_browser versions: :modern`,
  # config/application.rb), so adding style-src here wouldn't tighten
  # anything — it would silently make every hotel's branding disappear,
  # since inline style="" *attributes* can never carry a nonce to begin
  # with. Leaving style-src off this list is what keeps its 'unsafe-inline'
  # actually in effect.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]
end
