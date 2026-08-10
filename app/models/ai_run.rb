# One attempt to use a model, recorded whatever happened.
#
# Every path through Ai::GenerateReplyJob writes exactly one of these,
# including the paths where no HTTP request was ever made — a run blocked by
# the budget or by an open circuit breaker is the most important row in the
# table, because it is the only trace that a guest was answered by a fallback
# message rather than by the concierge.
class AiRun < ApplicationRecord
  include TenantScoped

  enum :kind, { reply: 0, translation: 1 }

  # `success` means the model answered. Everything else is a specific
  # failure the degradation path handled, named so that "why did guests get
  # the fallback message on Tuesday" is one query rather than an
  # investigation.
  enum :status, {
    success: 0, timeout: 1, api_error: 2,
    refusal: 3, budget_blocked: 4, circuit_open: 5
  }

  belongs_to :conversation, optional: true
  belongs_to :message, optional: true

  scope :today_in, ->(timezone) {
    where(created_at: Time.current.in_time_zone(timezone).beginning_of_day..)
  }

  # What the daily budget guard reads. Cached reads are billed at a fraction
  # of the input price, but they are still input tokens and a hotel whose
  # prompt is entirely cache hits is still consuming context — counting them
  # keeps the budget an honest ceiling on usage rather than on price.
  #
  # Output tokens are counted too: they are five times the price of input,
  # so a budget that ignored them would be a budget in name only.
  def self.tokens_used_today(hotel)
    where(hotel: hotel).today_in(hotel.timezone)
      .sum(Arel.sql("COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)"))
  end

  # True when this hotel has spent at least `fraction` of its daily budget.
  # The concierge stops at 90%; translation (Slice 5) is allowed all the way
  # to 100%, because staff-to-guest communication is the lifeline that has to
  # outlive the assistant.
  #
  # A budget of zero therefore reads as "exhausted", not as "unlimited". That
  # is the deliberate direction: a hotel that types 0 into a field labelled
  # "daily token budget" means no AI, and guessing the other way would hand
  # them uncapped spend.
  def self.budget_exhausted_for?(hotel, fraction: 1.0)
    tokens_used_today(hotel) >= (hotel.ai_daily_token_budget.to_i * fraction)
  end
end
