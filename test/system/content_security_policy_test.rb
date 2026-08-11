require "application_system_test_case"

# Content-Security-Policy is enabled project-wide
# (config/initializers/content_security_policy.rb). A misconfigured header
# is silent under normal browsing — the browser just drops whatever it
# disallows, with no error a human would see without opening devtools — so
# "the tests still pass" proves nothing here unless the tests actually run
# against a real browser enforcing the real header. These do: a real
# headless Chrome, subject to the CSP this app sends, on the two page shapes
# most likely to break under a real policy — a page-specific inline <style>
# block (the QR print sheet) and hotel-branded inline style="" attributes.
class ContentSecurityPolicyTest < ApplicationSystemTestCase
  test "the QR print sheet's page-specific stylesheet still applies under the real CSP" do
    sign_in_as users(:stari_admin), password: "password123"

    visit print_staff_qr_code_path

    # The sheet's <style> block only takes effect under print media
    # (@media print hides nav/header and resizes for an A5 card) — silent
    # under ordinary browsing either way, which is exactly the trap: only
    # emulating an actual print renders the risk visible at all.
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", media: "print")

    assert_equal "none", page.evaluate_script("getComputedStyle(document.querySelector('nav')).display")
  end

  test "a hotel's inline branding style attribute still applies under the real CSP" do
    sign_in_as users(:stari_admin), password: "password123"

    # Script execution disabled *for the page* before visiting, not for our
    # own evaluate_script calls below (a separate, out-of-band DevTools
    # channel Chrome doesn't gate the same way): the swatch this test checks
    # is also a Stimulus target, and brand_preview_controller.js repaints it
    # with the very same color via element.style.backgroundColor the moment
    # it connects — a JS-driven style mutation CSP's style-src never
    # governs. Left running, that JS repaint would silently mask a
    # style-src regression that dropped the *static*, server-rendered
    # style="" attribute this test exists to check.
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit edit_staff_hotel_settings_path

    swatch_color = page.evaluate_script(
      "getComputedStyle(document.querySelector('[data-brand-preview-target=\"primarySwatch\"]')).backgroundColor"
    )

    # hotels(:stari_grad).primary_color is #1F3A5F — rendered server-side as
    # a plain style="background-color:#1F3A5F" attribute
    # (app/views/staff/hotel_settings/edit.html.erb).
    assert_equal "rgb(31, 58, 95)", swatch_color
  end

  test "Stimulus still runs under the real CSP script-src nonce" do
    sign_in_as users(:stari_admin), password: "password123"

    visit edit_staff_hotel_settings_path
    # staff.hotel_settings.edit.primary_color_label (config/locales/staff.bs.yml)
    # — stari_admin reads the staff workspace in Bosnian.
    fill_in "Primarna boja", with: "#334455"

    # The swatch only updates on an `input` event handled by
    # brand_preview_controller.js — if importmap-rails' nonce on the inline
    # module-loader script tag didn't match the CSP header, that controller
    # would never connect and this would still read the server-rendered
    # #1F3A5F.
    swatch_color = page.evaluate_script(
      "getComputedStyle(document.querySelector('[data-brand-preview-target=\"primarySwatch\"]')).backgroundColor"
    )
    assert_equal "rgb(51, 68, 85)", swatch_color
  end

  private
    # Both fixtures used here (stari_admin) read the staff workspace in
    # Bosnian — see test/fixtures/users.yml — so the post-sign-in page
    # renders staff.layout.signed_in_as_html's Bosnian "Prijavljeni ste
    # kao %{name}" (config/locales/staff.bs.yml), not the English literal.
    def sign_in_as(user, password:)
      visit root_url
      fill_in "email_address", with: user.email_address
      fill_in "password", with: password
      click_on "Sign in"
      assert_text "Prijavljeni ste kao #{user.name}"
    end
end
