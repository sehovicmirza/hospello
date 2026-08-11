# Hospello

Hospello gives hotel guests an AI concierge over a branded, mobile-first web
chat — scan the QR code in the room, chat in your own language, get grounded
answers from that hotel's own knowledge base, and raise service requests
(towels, a wake-up call, a maintenance issue) that land on the front desk's
live dashboard. Each hotel is a fully isolated tenant with its own branding,
rooms, staff, and knowledge base. A later channel adds the hotel's own
branded WhatsApp number as a second way to reach the same concierge.

This repository is a single Rails 8 monolith (Hotwire/Turbo, Postgres doing
quadruple duty as the app database plus Solid Queue/Cache/Cable — no Redis,
no microservices) built for real hotel pilots, one hotel at a time.

> **Picking up development?** Start with **[HANDOVER.md](HANDOVER.md)** — current state, what's in
> flight, and what to do next. Then [CLAUDE.md](CLAUDE.md) for how to work in this repo, and
> [docs/plan/](docs/plan/) for the approved implementation plan, the per-slice task breakdowns, the
> engineering rules, and the known-issues list. This project is built across many sessions on
> different machines, so those files are the memory that carries between them.

**Current status (Slice 1 of the MVP plan):** the operational foundation —
multi-tenancy, platform-admin and hotel-admin back offices, staff accounts,
rooms/departments/categories, hotel branding, the reusable per-hotel QR
code, and everything in this document (ops, Render deployment, CI). The
guest-facing chat, the AI concierge itself, and the WhatsApp channel are
built in the slices that follow — see `docs/whatsapp-onboarding.md` for why
you can and should start that channel's paperwork now regardless.

## Three kinds of accounts

- **Platform admin** — a Hospello operator. Creates hotels, creates each
  hotel's first admin, suspends/reactivates hotels. Signs in at `/`.
- **Hotel admin** — a hotel's own staff member with full settings access:
  branding, rooms, departments, other staff accounts, the QR code.
- **Staff** — a hotel's front-desk/reception account. Everything except the
  admin-only settings screens.

## Local setup

Prerequisites: Ruby 3.4.3 (see `.ruby-version`) and a running local
PostgreSQL server (any recent version; developed against 12+). No Node.js
and no JS package manager — Hotwire (Turbo/Stimulus) and Tailwind both run
through Ruby gems (`importmap-rails`, `tailwindcss-rails`), so there is no
separate frontend build chain to install.

```bash
git clone <this repo>
cd hospello
bin/setup            # bundle install, clears any stale public/assets,
                      # bin/rails db:prepare, clears logs/tmp, starts bin/dev
```

`bin/setup` ends by launching `bin/dev` (Puma + `bin/rails tailwindcss:watch`
via `Procfile.dev`). Pass `--skip-server` to stop after setup without
starting the app. Visit `http://localhost:3000`.

The app boots with no `.env` file — every variable in `.env.example` has a
safe default or is only required in production. Copy it to `.env` and fill
in values only for the pieces you're actively working on (see the table
below); dotenv-rails loads `.env` automatically in development and test.

To create your own local platform admin, either run
`PLATFORM_ADMIN_EMAIL=you@example.com PLATFORM_ADMIN_PASSWORD=... bin/rails db:seed`
or sign up through `bin/rails console` with `User.create!(role: :platform_admin, ...)`.

## Running the tests

```bash
bin/rails test           # unit + controller + integration (Minitest)
bin/rails test:system    # Capybara + headless Chrome
bundle exec rubocop      # style (rubocop-rails-omakase)
bundle exec brakeman --no-pager        # static security scan
bundle exec bundler-audit check --update   # dependency CVEs
```

System tests need a real Chrome on your machine (any recent version —
`selenium-webdriver`'s bundled Selenium Manager resolves a matching
chromedriver automatically). `.github/workflows/ci.yml` runs the exact same
six commands, in the same order, against a fresh Postgres service container
on every push and pull request — see "Continuous integration" below.

## Environment variables

Every variable the app reads, with production-vs-local applicability. Full
one-line comments live in `.env.example` — copy it to `.env` for local
development. **Never commit real values for any of these.**

| Variable | Required in production? | Purpose |
|---|---|---|
| `APP_HOST` | Yes — boot fails without it | Bare hostname guests reach; encoded into every printed QR code |
| `DATABASE_URL` | Yes | Postgres connection string (Render sets this automatically) |
| `RAILS_MASTER_KEY` | Yes | Decrypts `config/credentials.yml.enc` |
| `PLATFORM_ADMIN_EMAIL` / `PLATFORM_ADMIN_PASSWORD` | Only for first boot | Seeds the first Hospello operator account (idempotent) |
| `PLATFORM_ADMIN_NAME` | No | Defaults to "Hospello Operator" |
| `SEED_DEMO` | No | Set to `1` to also load `db/seeds/demo.rb` (currently a stub) |
| `SOLID_QUEUE_IN_PUMA` | Yes (pilot topology) | Runs the job supervisor inside the web process — no separate worker service |
| `WEB_CONCURRENCY` | No | Puma worker process count (default 1) |
| `RAILS_MAX_THREADS` | No | Puma thread count and the DB connection pool size (default 5) |
| `RAILS_LOG_LEVEL` | No | Defaults to `info`; avoid `debug` in production (can log PII) |
| `PORT` / `PIDFILE` | No | Puma listen port (default 3000) / pidfile path |
| `ACTIVE_STORAGE_SERVICE` | No | Forces `local` or `r2`; auto-picks `r2` once `R2_BUCKET` is set |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ENDPOINT` / `R2_BUCKET` | Recommended | Cloudflare R2 storage for hotel logos/welcome images — without these, uploads live on the container's ephemeral disk and are lost on redeploy |
| `ANTHROPIC_API_KEY` | Recommended | The AI concierge and (later) translation. Without it the app still boots and runs fully — guests chat, staff reply — and any AI call degrades to "reception will reply personally" |
| `AI_MODEL` | No | Concierge model id; defaults to `claude-opus-5` |
| `TRANSLATION_MODEL` | No | Translation model id; defaults to `claude-haiku-4-5`. Deliberately separate from `AI_MODEL` — translation is the guest-to-receptionist lifeline and must survive the concierge being switched off |
| `LIVE_AI` | Never in production or CI | Set to `1` locally to run `test/services/ai/live_smoke_test.rb`, which makes one real API call |
| `WHATSAPP_ACCESS_TOKEN` | Only once a hotel is connected (Slice 6) | Meta Cloud API system-user token — one for the whole app, not per hotel. Without it the app still boots and runs fully; `Whatsapp::MetaCloudProvider` raises a clear `Whatsapp::ApiError` if something asks it to send |
| `WHATSAPP_API_VERSION` | No | Meta Graph API version; defaults to `v22.0` |
| `SENTRY_DSN` | Recommended | Error tracking; every `Sentry.*` call is a no-op when unset |
| `HEARTBEAT_URL` | Recommended | An external uptime monitor's ping URL — see `docs/runbook.md` |
| `CI` | Set automatically by GitHub Actions | Forces eager loading in the test environment to catch autoload bugs |

## Deploy to Render

This is written for the person actually doing the deploy — no prior
familiarity with this codebase assumed. `render.yaml` is a
[Render Blueprint](https://render.com/docs/blueprint-spec): Render reads it
and creates every resource it describes in one pass.

### 1. Push credentials Render will need

Before you start, have these three values ready:

- `RAILS_MASTER_KEY` — run `cat config/master.key` in a checkout that has it
  (it's gitignored, so ask whoever set up the repo, or generate a fresh one
  with `bin/rails credentials:edit` if you're bootstrapping from scratch —
  that rewrites `config/credentials.yml.enc` too, so only do this once).
- A platform-admin email and a strong password of your choosing — you'll
  set these as `PLATFORM_ADMIN_EMAIL` / `PLATFORM_ADMIN_PASSWORD` and they
  create the first sign-in account automatically on first boot.
- The GitHub repo URL (this one), on the `main` branch.

### 2. Create the Blueprint

1. In the [Render dashboard](https://dashboard.render.com), click **New >
   Blueprint**.
2. Connect this GitHub repository and select the `main` branch. Render
   detects `render.yaml` at the repo root automatically.
3. Render lists the resources `render.yaml` defines: one **web service**
   (`hospello`) and one **Postgres database** (`hospello-db`), both in the
   Frankfurt region on the free tier by default (see the cost/upgrade notes
   at the top of `render.yaml` — flip `plan: free` to `plan: starter` for
   the web service before any real hotel pilot, so it doesn't sleep after
   15 minutes of inactivity).
4. Render prompts for every environment variable marked `sync: false` in
   `render.yaml` — these are the secrets, never stored in the repo. Fill in
   at minimum:
   - `RAILS_MASTER_KEY` — from step 1.
   - `APP_HOST` — the bare host you'll use. If you don't have a custom
     domain yet, use the `*.onrender.com` hostname Render assigns this
     service (visible on the service's page after creation) — **without**
     the `https://` scheme Render's dashboard displays it with; see the
     comment on `APP_HOST` in `render.yaml` for exactly why that distinction
     matters (it silently breaks every printed QR code otherwise).
   - `PLATFORM_ADMIN_EMAIL` / `PLATFORM_ADMIN_PASSWORD` — from step 1.
   - `ANTHROPIC_API_KEY`, `R2_*`, `SENTRY_DSN`, `HEARTBEAT_URL` — optional
     for a first deploy; every one of them is inert until set (see the env
     var table above). Leave them blank and revisit later.
5. Click **Apply**. Render provisions the database, then builds and deploys
   the web service. Watch the build logs — the build runs
   `bin/render-build.sh` (`bundle install`, asset precompile, `db:migrate`,
   `db:seed`), then starts `bundle exec puma -C config/puma.rb`.

### 3. Confirm it's alive

Once the deploy shows "Live":

1. Visit `https://<your-app-host>/up` — expect a plain `200 OK`. This is
   the health check Render's own load balancer polls continuously.
2. Visit `https://<your-app-host>/` — the sign-in page. Sign in with the
   `PLATFORM_ADMIN_EMAIL` / `PLATFORM_ADMIN_PASSWORD` you set in step 4
   above (the build's `db:seed` step created that account idempotently on
   first boot — safe to redeploy any number of times afterward). Signing in
   takes a platform admin straight to the hotel list at
   `/platform/hotels` — that's also where the next step picks up.

### 4. Create the first hotel

You should already be looking at the hotel list after signing in above (a
platform admin lands there directly; it's also the **Hotels** link on every
platform-admin page after that). If not, it's at
`https://<your-app-host>/platform/hotels`:

1. Click **New hotel**, fill in its name and settings, and save.
2. On the hotel's page, click **Create first admin** — this is the account
   you hand to the hotel's own staff. Hospello sends no invitation
   email and there is no self-service password reset anywhere in this
   product yet: you type the password on this screen and read it back to
   them over whatever channel you're using to onboard them (call, secure
   message — never plain email).
3. Sign the hotel admin in (or walk them through it) to finish branding,
   add rooms/departments, invite the rest of their staff, and download the
   QR code from **QR code** in the staff nav — that's the code to print and
   place in guest rooms and common areas. Changing `APP_HOST` later means
   every previously printed QR code breaks and has to be reprinted, so get
   it right before this step.

That completes acceptance scenario 13: the app deployed and operated on
Render end to end, using only the steps documented here.

### Redeploying and running migrations

Every push to `main` triggers a new Render build automatically
(`buildCommand: ./bin/render-build.sh` in `render.yaml`), which runs
`db:migrate` as part of the build on the free tier (see the comment in
`bin/render-build.sh` for why: Render's `preDeployCommand` — the
zero-downtime ordering — is a paid-instance-type feature only). Once you
upgrade the web service beyond `free`, move that `db:migrate` line from
`bin/render-build.sh` into `render.yaml`'s `preDeployCommand:` instead, per
the comments in both files.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request: a Postgres 16 service container, Ruby from `.ruby-version`, a real
headless Chrome (installed explicitly via `browser-actions/setup-chrome`,
not assumed to already be on the runner), then in order —
`bin/rails db:prepare`, `bin/rails test`, `bin/rails test:system`,
`bundle exec rubocop`, `bundle exec brakeman --no-pager`,
`bundle exec bundler-audit check --update`. Any failing step stops the run.

## Further reading

- `docs/runbook.md` — how to check queue health, read Sentry, suspend a
  hotel, and rotate a leaked QR code, for whoever is on call.
- `docs/whatsapp-onboarding.md` — the WhatsApp channel's onboarding
  checklist: what Hospello does, what each hotel must provide, and what's
  on Meta's timeline rather than ours.
