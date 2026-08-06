ActsAsTenant.configure do |config|
  # Fail closed: a query on a tenant-scoped model outside a tenant context raises
  # instead of silently returning every hotel's rows.
  config.require_tenant = true
end
