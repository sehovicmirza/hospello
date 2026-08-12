require "test_helper"

# config/recurring.yml is the one file in this app whose mistakes are silent
# in exactly the way that matters: a job named there that does not resolve to
# a class is not an error anybody sees, it is a job that never runs. Nothing
# in the test suite executes this file, and nothing in production complains
# about it — the work simply does not happen, for as long as it takes someone
# to notice its effects are missing.
#
# For most of the schedule that would be an annoyance. For the retention
# purge it is a legal promise quietly not being kept, in a way that is
# unrecoverable by the time anyone finds out: the data was supposed to be
# gone months ago and it is all still there.
class RecurringScheduleTest < ActiveSupport::TestCase
  SCHEDULE = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").freeze

  test "every scheduled job names a class that actually exists" do
    unresolvable = SCHEDULE.filter_map do |name, task|
      class_name = task["class"]
      next if class_name.blank? # a `command:` entry, not a job

      name unless class_name.safe_constantize
    end

    assert_empty unresolvable,
      "these recurring entries name a class that does not resolve: #{unresolvable.join(', ')} — " \
      "in production they simply never run, and nothing reports it"
  end

  test "every scheduled job is a real ActiveJob and can be performed with no arguments" do
    wrong = SCHEDULE.filter_map do |name, task|
      class_name = task["class"]
      next if class_name.blank?

      job = class_name.safe_constantize
      next name unless job.respond_to?(:perform_now)

      # Solid Queue passes `args` (none of ours take any), so a #perform that
      # requires one would raise on every tick, in a worker's log, forever.
      name if job.instance_method(:perform).arity.positive?
    end

    assert_empty wrong, "these recurring entries cannot be run as scheduled: #{wrong.join(', ')}"
  end

  test "the retention purge is scheduled at all" do
    entry = SCHEDULE["purge_expired_guest_data"]

    assert entry, "nothing in config/recurring.yml runs Retention::PurgeExpiredGuestDataJob — " \
                  "the policy in app/services/retention/policy.rb is then a document, not a promise"
    assert_equal "Retention::PurgeExpiredGuestDataJob", entry["class"]
    assert_match(/every day/, entry["schedule"])
  end
end
