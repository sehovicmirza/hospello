module Platform
  # Platform admins work across hotels, so this namespace deliberately sets no
  # ambient tenant: every tenant-scoped query here must name its hotel, and it is
  # the only namespace where ActsAsTenant.without_tenant is permitted
  # (see test/tenancy/without_tenant_grep_test.rb).
  class BaseController < ApplicationController
    before_action :require_platform_admin

    protected
      def audit!(action, target: nil, hotel: nil, **metadata)
        AuditLog.record!(actor: Current.user, action: action, hotel: hotel, target: target, metadata: metadata)
      end

    private
      # active? matters as much as the role: sessions are permanent cookies that
      # nothing revokes, so deactivating an account is the only way to take away
      # cross-hotel access.
      def require_platform_admin
        head :forbidden unless Current.user&.platform_admin? && Current.user.active?
      end
  end
end
