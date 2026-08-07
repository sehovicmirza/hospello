# The production APP_HOST value, resolved and normalized in exactly one
# place — review round 1 found config/environments/production.rb and
# Staff::QrCodesController each reading ENV["APP_HOST"] independently, with
# two different failure modes when it was missing (a silent "example.com"
# mailer fallback vs. a controller KeyError only a receptionist's click
# would surface). Both now call this instead.
#
# Render's dashboard *displays* a deployed service's URL with a scheme
# ("https://hospello.onrender.com") even though render.yaml's APP_HOST
# comment asks for the bare host — pasting that displayed value is the
# likely operator mistake, and left unnormalized it silently doubles the
# scheme into a dead "https://https://.../h/..." URL on every printed QR
# code. Stripping surrounding whitespace, a leading http(s)://, and a
# trailing slash makes that mistake harmless instead of a reprint.
class AppHost
  MISSING_MESSAGE = "APP_HOST must be set in production — see render.yaml".freeze

  def self.resolve!(env = ENV)
    raw = env["APP_HOST"]
    raise MISSING_MESSAGE if raw.blank?

    normalize(raw)
  end

  def self.normalize(raw)
    raw.to_s.strip.sub(%r{\Ahttps?://}i, "").chomp("/")
  end
end
