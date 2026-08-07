# Rails casts an unrecognized boolean input — most commonly the empty
# string a stray or hand-crafted `active` param produces (curl, a form
# field with no hidden "0" default) — to `nil`, not `false`
# (ActiveModel::Type::Boolean#cast_value). Users, Rooms, and Departments all
# declare `active boolean, null: false`, so without this validation that nil
# sails straight through to Postgres and raises an unrescued
# ActiveRecord::NotNullViolation — a 500 — instead of a normal, rescued
# validation error the controller re-renders with. One shared concern
# instead of three near-identical `validates :active, inclusion: ...` lines.
module Activatable
  extend ActiveSupport::Concern

  included do
    validates :active, inclusion: { in: [ true, false ] }
  end
end
