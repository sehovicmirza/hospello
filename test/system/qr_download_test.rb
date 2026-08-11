require "application_system_test_case"

# Acceptance scenario 2's headline moment: a hotel admin downloads the
# hotel's reusable QR code. Kept to one short, focused test per the house
# rules — the print sheet's four-language content and the powered-by toggle
# are already covered at the controller level
# (test/controllers/staff/qr_codes_controller_test.rb); this test only
# proves the nav link is wired to a real page in a real browser and that the
# download affordances are actually on it.
class QrDownloadTest < ApplicationSystemTestCase
  test "a hotel admin reaches the QR code page from the nav and finds the download links" do
    sign_in_as users(:stari_admin), password: "password123"

    visit staff_root_path
    # stari_admin reads the staff workspace in Bosnian — staff.nav.qr_code
    # and staff.qr_codes.show.download_svg/download_png
    # (config/locales/staff.bs.yml), pasted literally.
    click_on "QR kod"

    assert_current_path staff_qr_code_path
    assert_match %r{\Ahttps://.+/h/stari-grad\z}, find("#qr-url").text
    assert_selector "a[href='#{staff_qr_code_path(format: :svg)}']", text: "Preuzmi SVG"
    assert_selector "a[href='#{staff_qr_code_path(format: :png)}']", text: "Preuzmi PNG"
  end

  # Review round 1, IMPORTANT 3: dir="rtl" alone reorders characters/bidi,
  # not alignment — a controller test can only see the markup (the
  # text-start class, the dir attribute), not what actually renders. Chrome
  # reports `getComputedStyle().textAlign` for a logical value as the
  # literal string "start" (it does not resolve to "left"/"right" at the
  # computed-value stage), so that alone can't distinguish "correctly
  # direction-aware" from "coincidentally never resolved" — this instead
  # measures where the text actually lands: for right-aligned content the
  # paragraph's right edge should sit almost flush with its container's
  # right edge, with the gap on the left, which is the literal geometric
  # meaning of "hugs the left edge" the review called out.
  test "the Arabic line on the print sheet is actually right-aligned, not just right-to-left ordered" do
    sign_in_as users(:stari_admin), password: "password123"

    visit print_staff_qr_code_path

    gaps = page.evaluate_script(<<~JS)
      (() => {
        // The <p> itself is a block box that spans the full container width
        // regardless of text-align — only the glyphs inside it move. A
        // Range over the text node gives the actual rendered text's
        // bounding box, which is what needs to sit near the right edge.
        const p = document.querySelector('[lang="ar"] p');
        const container = document.querySelector('#language-lines');
        const range = document.createRange();
        range.selectNodeContents(p.firstChild);
        const textRect = range.getBoundingClientRect();
        const containerRect = container.getBoundingClientRect();
        return {
          left: textRect.left - containerRect.left,
          right: containerRect.right - textRect.right
        };
      })()
    JS

    assert_operator gaps["right"], :<, gaps["left"],
      "expected the Arabic paragraph to sit flush with the right edge (right gap #{gaps["right"]} < left gap #{gaps["left"]}), " \
      "but it measured closer to the left edge — it is rendering left-aligned"
  end

  private
    # `click_on` returns when the click is dispatched, not when the resulting
    # page has loaded — asserting on the destination makes the click and its
    # navigation a single step, matching the other system tests in this project.
    #
    # stari_admin reads the staff workspace in Bosnian — see
    # test/fixtures/users.yml — so this is staff.layout.signed_in_as_html's
    # Bosnian text (config/locales/staff.bs.yml), pasted literally.
    def sign_in_as(user, password:)
      visit root_url
      fill_in "email_address", with: user.email_address
      fill_in "password", with: password
      click_on "Sign in"
      assert_text "Prijavljeni ste kao #{user.name}"
    end
end
