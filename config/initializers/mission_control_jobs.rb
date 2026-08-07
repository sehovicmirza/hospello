# Mission Control – Jobs (Solid Queue's dashboard) is mounted at
# /platform/jobs — see config/routes.rb — inside the platform-admin
# namespace.
#
# base_controller_class points every Mission Control controller at
# Platform::BaseController, which already refuses anyone but a signed-in,
# active platform_admin (#require_platform_admin) via our normal session
# auth. Disabling the gem's own HTTP Basic Auth on top of that isn't
# loosening anything: it would just be a second, unused credential (managed
# via `rails credentials:edit`, no relation to how anyone actually signs in
# to this app) guarding the same door our session auth already guards —
# and leaving it enabled with no credentials configured would make the
# dashboard 401 for a signed-in platform admin instead of protecting it
# further.
MissionControl::Jobs.base_controller_class = "Platform::BaseController"
MissionControl::Jobs.http_basic_auth_enabled = false
