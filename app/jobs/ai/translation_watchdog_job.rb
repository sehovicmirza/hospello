module Ai
  # Settles translations that never came back.
  #
  # A message left in `pending` or `translating` because its job died, or
  # because the queue backed up, is a bubble that says "translating…" forever.
  # That is worse than showing the original: the reader is waiting for
  # something that is not coming, and the one thing this product must never do
  # is leave someone at a dead end.
  #
  # So the budget is not about *delivery* — the message was delivered the
  # moment it was written (see Ai::TranslateMessageJob). It is about how long
  # a reader is asked to wait before the original becomes the final answer.
  class TranslationWatchdogJob < ApplicationJob
    include TenantFree

    queue_as :low

    # A receptionist waiting longer than this has already opened the chip and
    # read the guest's own words. Past that point the translation is not worth
    # holding a bubble open for, and if it does arrive later it still lands as
    # an overlay — the job that owns it is not cancelled, only overtaken.
    BUDGET = 15.seconds

    def perform
      Hotel.find_each do |hotel|
        ActsAsTenant.with_tenant(hotel) { settle_overdue_for(hotel) }
      end
    end

    private
      def settle_overdue_for(hotel)
        hotel.messages.translation_overdue(BUDGET).find_each do |message|
          message.update!(translation_status: :failed)
          message.conversation.broadcast_translation(message)
        end
      end
  end
end
