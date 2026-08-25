class AddPlanToHotels < ActiveRecord::Migration[8.1]
  # Which of the three subscription plans a hotel is on. See Hotel::PLAN_FEATURES
  # for what each one buys.
  #
  # The default is `service` (1), not `essentials` (0), even though Essentials is
  # the plan being sold. Two reasons, and they point the same way:
  #
  #   1. Every hotel that exists when this runs — including the five live demo
  #      hotels — is a full-featured hotel today. Defaulting to `service` means
  #      this migration changes nothing for any of them, which is what a column
  #      addition should do.
  #   2. Eighteen tests build a Hotel inline without naming a plan, several of
  #      them (test/helpers/staff_helper_test.rb) about the very nav this
  #      feature gates. Defaulting to `essentials` would turn them red for a
  #      reason unrelated to what they assert.
  #
  # "What we sell" lives in the platform admin's create form, which preselects
  # Essentials — that is where a human actually chooses. Every non-form creation
  # path (db/seeds/demo.rb) names its plan explicitly.
  #
  # Postgres applies a non-volatile default as catalogue metadata, so existing
  # rows are backfilled without rewriting the table.
  def change
    add_column :hotels, :plan, :integer, null: false, default: 1
  end
end
