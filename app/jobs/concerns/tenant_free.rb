# Marker for jobs that legitimately run without a tenant: cross-hotel
# maintenance work that iterates hotels itself (nightly sweeps, platform
# reports) and therefore cannot be handed a single hotel up front.
#
# Including this skips ApplicationJob's tenant hook, so such a job must set the
# tenant for each hotel it touches — ActsAsTenant.with_tenant(hotel) { ... }.
module TenantFree
end
