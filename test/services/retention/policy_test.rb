require "test_helper"

module Retention
  # The policy is a file of numbers and reasons, so most of what could be
  # asserted about it would be a tautology. These four are not:
  #
  #   - the numbers themselves, pinned, so changing a legal promise shows up
  #     in a diff as a changed test rather than as a changed constant (the
  #     same reasoning Ai::TranslationWatchdogJob::BUDGET's own test carries);
  #   - **completeness** — every table that can hold a hotel's data has a
  #     decision written against it, so a future table cannot arrive without
  #     one;
  #   - every decision carries a reason, including the ones that keep a row
  #     forever, which are the decisions most likely to be made by omission;
  #   - the analytics cap follows the policy, rather than the two drifting
  #     into a page that shows a deletion as a decline in business.
  class PolicyTest < ActiveSupport::TestCase
    test "the guest's own conversation is kept for ninety days" do
      assert_equal 90, Policy::GUEST_CHAT_DAYS
    end

    test "the hotel's operational record of a request is kept for a year" do
      assert_equal 365, Policy::OPERATIONAL_DAYS
    end

    test "a raw provider callback is kept for thirty days" do
      assert_equal 30, Policy::WEBHOOK_EVENT_DAYS
    end

    # The load-bearing one. Every table with a hotel_id can hold something
    # about a guest, so every one of them needs an answer to "how long do we
    # keep this, and why" — including the ones whose answer is "for as long
    # as the hotel is a customer". Scanned the same way
    # test/tenancy/tenant_declaration_test.rb scans for missing acts_as_tenant
    # declarations, for the same reason: a rule somebody has to remember to
    # add is a rule that will eventually be missing.
    test "every table that can hold a hotel's data has a retention decision" do
      Rails.application.eager_load!

      undecided = ApplicationRecord.descendants.reject(&:abstract_class?).filter_map do |model|
        next unless model.column_names.include?("hotel_id")

        model.table_name.to_sym unless Policy::BY_RECORDS.key?(model.table_name.to_sym)
      end.uniq

      assert_empty undecided,
        "these tables can hold a hotel's data and are not named in Retention::Policy::RULES: " \
        "#{undecided.join(', ')} — decide how long each is kept and why, then add a Rule"
    end

    test "every rule says why, including the ones that keep a row indefinitely" do
      unexplained = Policy::RULES.reject { |rule| rule.why.to_s.length > 40 }.map(&:records)

      assert_empty unexplained,
        "these rules have no real reason written against them: #{unexplained.join(', ')}"
    end

    # A window with no anchor is not a policy, it is a number: "90 days" is
    # unanswerable without "90 days from what".
    test "every rule with a window says what its clock starts from" do
      anchorless = Policy::RULES.filter_map do |rule|
        next if rule.delete_after_days.nil? && rule.redact_after_days.nil?

        rule.records if rule.anchor.blank?
      end

      assert_empty anchorless, "these rules name a window but no anchor: #{anchorless.join(', ')}"
    end

    test "the analytics horizon is the shortest window among the tables those pages count" do
      assert_equal 90, Policy.analytics_horizon_days
      assert_equal Policy.rule_for(:conversations).delete_after_days, Policy.analytics_horizon_days
    end

    # The whole reason this is here: Analytics::HotelReport::MAX_DAYS was 366,
    # chosen for query cost. Conversations and messages are deleted at 90 days,
    # so a hotel asking for a year got months of zeros that read as a collapse
    # in business rather than as a purge working correctly.
    test "the analytics page cannot be asked to look back further than the data survives" do
      assert_equal Policy.analytics_horizon_days, Analytics::HotelReport::MAX_DAYS
    end

    test "each cutoff is its own window back from the moment it is asked" do
      now = Time.zone.local(2026, 8, 12, 3, 0, 0)

      assert_equal now - 90.days, Policy.guest_chat_cutoff(now)
      assert_equal now - 365.days, Policy.operational_cutoff(now)
      assert_equal now - 30.days, Policy.webhook_event_cutoff(now)
    end

    # Read when the job runs, not when the class was loaded: a Solid Queue
    # worker lives for weeks, and a constant frozen at boot would purge
    # against the moment the process started for as long as it ran.
    test "a cutoff asked for twice moves with the clock" do
      first = Policy.guest_chat_cutoff
      travel 1.day do
        assert_operator Policy.guest_chat_cutoff, :>, first
      end
    end
  end
end
