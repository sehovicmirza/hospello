namespace :ai_usage do
  # Fills ai_usage_days from the ai_runs rows that already exist.
  #
  # Run once after deploying the rollup (Slice 7 Task 1); after that every run
  # records itself from AiRun's own after_create_commit and this is only ever
  # a repair.
  #
  # **Idempotent**: AiUsageDay.rebuild_for replaces a day's counters rather
  # than adding to them, so running this twice produces the same numbers
  # rather than double. That is the opposite of what the live write path does,
  # and it is the reason the two are separate methods — see the model.
  desc "Rebuild ai_usage_days from ai_runs (idempotent; safe to re-run)"
  task backfill: :environment do
    total = 0

    # Hotel is not tenant-scoped (it *is* the tenant), so iterating it needs no
    # ambient tenant — but everything inside does, hence with_tenant per hotel.
    # Same shape as Ai::TranslationWatchdogJob.
    Hotel.find_each do |hotel|
      days = ActsAsTenant.with_tenant(hotel) { AiUsageDay.rebuild_for(hotel) }
      total += days
      puts "#{hotel.slug}: #{days} day/kind rows"
    end

    puts "Rebuilt #{total} rows across #{Hotel.count} hotels."
  end
end
