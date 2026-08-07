require "test_helper"

# AppHost is the single place ENV["APP_HOST"] is read and validated, so
# config/environments/production.rb (Action Mailer) and
# Staff::QrCodesController (the printed QR code) can't reach two different
# conclusions about it or fail two different ways when it's missing —
# review round 1 found exactly that split (a silent "example.com" mailer
# fallback next to a controller that raised only when a receptionist
# clicked). Every case here is exercised against a plain Hash, not real
# ENV, so it needs no Rails boot state and cannot leak between tests.
class AppHostTest < ActiveSupport::TestCase
  test "returns the bare host unchanged" do
    assert_equal "hospello.onrender.com", AppHost.resolve!({ "APP_HOST" => "hospello.onrender.com" })
  end

  # Render's dashboard *displays* a deployed service's URL with a scheme
  # ("https://hospello.onrender.com") even though render.yaml's APP_HOST
  # comment asks for the bare host — pasting that displayed value is the
  # likely operator mistake, and unnormalized it silently doubles the
  # scheme into a dead "https://https://.../h/..." URL on every printed QR
  # code (review round 1's evidence table).
  test "strips a leading https:// — the value Render's dashboard displays, not what render.yaml asks for" do
    assert_equal "hospello.onrender.com", AppHost.resolve!({ "APP_HOST" => "https://hospello.onrender.com" })
  end

  test "strips a leading http://" do
    assert_equal "hospello.onrender.com", AppHost.resolve!({ "APP_HOST" => "http://hospello.onrender.com" })
  end

  test "strips surrounding whitespace" do
    assert_equal "hospello.onrender.com", AppHost.resolve!({ "APP_HOST" => " hospello.onrender.com " })
  end

  test "chomps a trailing slash" do
    assert_equal "hospello.onrender.com", AppHost.resolve!({ "APP_HOST" => "hospello.onrender.com/" })
  end

  test "handles a pasted full URL with a trailing slash in one go" do
    assert_equal "hospello.onrender.com", AppHost.resolve!({ "APP_HOST" => " https://hospello.onrender.com/ " })
  end

  test "raises with a clear, actionable message when APP_HOST is unset" do
    error = assert_raises(RuntimeError) { AppHost.resolve!({}) }
    assert_equal AppHost::MISSING_MESSAGE, error.message
  end

  test "raises the same way when APP_HOST is set but blank" do
    error = assert_raises(RuntimeError) { AppHost.resolve!({ "APP_HOST" => "" }) }
    assert_equal AppHost::MISSING_MESSAGE, error.message
  end
end
