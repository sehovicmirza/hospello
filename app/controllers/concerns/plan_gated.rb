# Refuses a staff screen the hotel's subscription plan does not include.
#
# This is the second of two independent gates on every staff controller, and it
# deliberately does not live in Pundit. Every policy in app/policies answers
# "which role" — HotelConfigurationPolicy and ConversationPolicy both say so in
# their own comments — and a plan is not a role. The two questions have
# different answers and, more importantly, different remedies: a role refusal
# means "ask your manager", a plan refusal means "your hotel did not buy this",
# and only one of those is something a hotel_admin can act on.
#
# Keeping them apart is also what lets a plan refusal render a real page. A
# Pundit denial lands in ApplicationController#not_authorized, which is
# `render plain: "Not authorized"` — no layout, no translation, and no way to
# tell a receptionist what they are looking at.
#
# Declared per controller (`requires_plan_feature :requests`) rather than
# inferred from the controller name, so the list of what a plan gates is
# greppable and a new controller is never gated by accident.
module PlanGated
  extend ActiveSupport::Concern

  class_methods do
    def requires_plan_feature(feature)
      before_action { require_plan_feature!(feature) }
    end
  end

  private
    # Runs inside Staff::BaseController#scope_to_current_hotel's around_action,
    # so Current.hotel is always set by the time this is asked. The `&.` is not
    # defensive padding — Current is a per-request singleton and a controller
    # that ever ran this without a tenant would be a bug worth failing closed
    # on rather than one worth granting access through.
    def require_plan_feature!(feature)
      return if Current.hotel&.plan_allows?(feature)

      render "staff/shared/plan_upgrade",
        status: :forbidden,
        locals: { feature: feature }
    end
end
