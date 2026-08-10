module ServiceRequests
  # Closes drafts the guest walked away from.
  #
  # A half-finished request must not spring to life an hour later. A guest who
  # started "two extra towels…" and then went to dinner should come back to a
  # clean slate, not to a summary card for something they no longer want and
  # may not remember asking about — and certainly not to a towel delivery at
  # 23:00 because the assistant found an old draft and confirmed it.
  #
  # It also frees the one-live-draft slot, so the guest's next request is not
  # blocked by the one they abandoned.
  class ExpireDraftsJob < ApplicationJob
    include TenantFree

    queue_as :low

    # Hotel by hotel, inside a tenant block each time, rather than one
    # cross-hotel sweep. acts_as_tenant's escape hatch would be shorter and is
    # deliberately barred outside the platform namespace (see
    # test/tenancy/without_tenant_grep_test.rb): a maintenance job is exactly
    # the kind of code where a tenant-less query looks harmless, and is how a
    # cross-tenant read gets introduced. Iterating hotels costs one small
    # query each, five minutes apart.
    #
    # That tripwire is a plain text grep, so it fires on prose as readily as
    # on code — hence the escape hatch being described here rather than named.
    # Blunt is the right trade for a guard whose whole job is to be
    # impossible to talk past.
    def perform
      Hotel.find_each do |hotel|
        ActsAsTenant.with_tenant(hotel) { expire_drafts_for(hotel) }
      end
    end

    private
      def expire_drafts_for(hotel)
        # A validating write, deliberately, even though it would be tempting
        # to skip straight past the model here: a draft that cannot satisfy
        # its own validations is a bug worth hearing about, and silently
        # forcing the column would hide it. Nothing on this model validates
        # anything a persisted row can lose, so this is not a risk today —
        # if a future validation makes it one, the loud failure is the point.
        hotel.service_request_drafts.past_expiry.find_each { |draft| draft.update!(status: :expired) }
      end
  end
end
