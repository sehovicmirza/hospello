#!/usr/bin/env bash
# Render build script. Runs on every deploy, before the service starts.
set -o errexit

bundle install
bundle exec rails assets:precompile
bundle exec rails assets:clean

# Migrations run here rather than in a preDeployCommand because Render offers
# preDeployCommand only on paid instance types, and this blueprint defaults to
# the free tier. If you upgrade the web service to `starter` or above, move this
# line into `preDeployCommand:` in render.yaml — that runs migrations after the
# build but before the new version serves traffic, which is the zero-downtime
# ordering. Here, the new code is briefly live against the old schema.
bundle exec rails db:migrate

# Idempotent: creates the platform administrator on first boot, no-ops after.
bundle exec rails db:seed
