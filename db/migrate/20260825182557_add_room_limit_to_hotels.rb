class AddRoomLimitToHotels < ActiveRecord::Migration[8.1]
  # A per-hotel override of the room ceiling its plan is sold with.
  #
  # Nullable, and null is the normal state: it means "whatever this plan is sold
  # with" (Hotel::PLAN_ROOM_LIMITS), so a hotel follows its plan without anyone
  # having to write a number down, and changing what Essentials includes is a
  # one-line change to a constant rather than a data migration.
  #
  # It exists because the go-to-market is "20 rooms, then more rooms": selling
  # Essentials to a 24-room hotel is a near-term need, and the alternative —
  # inventing a fourth plan, or raising the cap for everyone — is worse than one
  # nullable integer.
  #
  # Zero is a real value here and means zero rooms allowed, distinct from null.
  # That is the opposite reading to ai_daily_token_budget, where 0 means
  # "exhausted, not unlimited" — and deliberately so: there, 0 is a number a
  # hotel typed into a budget field; here, "no ceiling" already has a spelling.
  def change
    add_column :hotels, :room_limit, :integer
  end
end
