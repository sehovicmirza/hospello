# Seeds are idempotent and safe to run on every deploy.
#
# The only thing seeded in every environment is the first platform administrator
# — the Hospello operator who creates hotels and their first hotel admins. It is
# created from environment variables so no credential ever lives in the repo.
#
# Demo data (a fully configured Sarajevo hotel for presenting the product) is
# separate and opt-in: set SEED_DEMO=1.

email = ENV["PLATFORM_ADMIN_EMAIL"].presence
password = ENV["PLATFORM_ADMIN_PASSWORD"].presence

if email && password
  admin = User.find_or_initialize_by(email_address: email.strip.downcase)

  if admin.new_record?
    admin.assign_attributes(
      name: ENV.fetch("PLATFORM_ADMIN_NAME", "Hospello Operator"),
      password: password,
      role: :platform_admin,
      hotel: nil
    )
    admin.save!
    puts "Seeded platform administrator #{admin.email_address}."
  else
    puts "Platform administrator #{admin.email_address} already exists — leaving it untouched."
  end
else
  puts "PLATFORM_ADMIN_EMAIL and PLATFORM_ADMIN_PASSWORD are not both set — skipping platform admin seed."
end

load Rails.root.join("db/seeds/demo.rb") if ENV["SEED_DEMO"] == "1"
