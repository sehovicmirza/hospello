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
      # acts_as_tenant serializes the enqueue-time tenant into the job and restores
      # it in deserialize, so a TenantFree job has to be actively cleared rather
      # than simply left alone: inheriting a tenant would silently narrow every
      # query it makes to whichever hotel happened to enqueue it.
      return ActsAsTenant.with_tenant(nil, &block) if is_a?(TenantFree)

      hotel = tenant_from_arguments
      if hotel.nil?
        raise ActsAsTenant::Errors::NoTenantSet,
          "#{self.class.name} was performed without a tenant: pass a Hotel or a hotel-scoped " \
          "record as an argument, or include TenantFree if it legitimately spans hotels"
      end

      ActsAsTenant.with_tenant(hotel, &block)
    end

    # Keyword arguments arrive as a trailing Hash, so its values are candidates too.
    def tenant_from_arguments
      candidates = arguments.flat_map { |argument| argument.is_a?(Hash) ? argument.values : [ argument ] }

      candidates.each do |candidate|
        return candidate if candidate.is_a?(Hotel)
        return candidate.try(:hotel) if candidate.respond_to?(:hotel_id) && candidate.hotel_id.present?
      end

      nil
    end
end
