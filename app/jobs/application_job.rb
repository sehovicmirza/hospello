class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # Background work runs outside a request, so nothing has set a tenant for it.
  # Rather than trusting whatever tenant happened to be current when the job was
  # enqueued, derive it from the job's own arguments — the hotel a job works on
  # is then always visible in the enqueued payload.
  around_perform :scope_to_tenant

  private
    def scope_to_tenant(&block)
      return yield if is_a?(TenantFree)

      hotel = tenant_from_arguments
      if hotel.nil?
        raise ActsAsTenant::Errors::NoTenantSet,
          "#{self.class.name} was performed without a tenant: pass a Hotel or a hotel-scoped " \
          "record as an argument, or include TenantFree if it legitimately spans hotels"
      end

      ActsAsTenant.with_tenant(hotel, &block)
    end

    def tenant_from_arguments
      arguments.each do |argument|
        return argument if argument.is_a?(Hotel)
        return argument.hotel if argument.respond_to?(:hotel_id) && argument.hotel_id.present?
      end

      nil
    end
end
