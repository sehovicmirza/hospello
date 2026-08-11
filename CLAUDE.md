# Hospello — instructions for any agent working on this repo

Hospello is a multi-tenant hotel guest-communication platform: one reusable QR code per hotel opens
a hotel-branded mobile web chat, guests identify themselves and talk to reception, an AI concierge
answers from that hotel's own knowledge base, and staff work the conversations and service requests
from a dashboard in their own language.

This project is built **incrementally by agents across many sessions, on different machines**,
including sessions the human is not watching. That only works if every session leaves the repo able
to explain itself to the next one. The three rules below are how that happens.

---

## 1. Read these before doing anything else

| File | What it is |
|---|---|
| **[HANDOVER.md](HANDOVER.md)** | **Start here.** Current state, what is done, what is next, and any traps waiting for you. Written by the previous session for you specifically. |
| [docs/plan/implementation-plan.md](docs/plan/implementation-plan.md) | The approved plan. Architecture, data model, the seven slices, and the reasoning behind each decision. This is the contract — do not redesign it unilaterally. |
| [docs/plan/engineering-rules.md](docs/plan/engineering-rules.md) | Hard-won rules, each one paid for with a real defect. **Read this even if you are in a hurry.** |
| [docs/plan/known-issues.md](docs/plan/known-issues.md) | Open problems, unverified assumptions, and deliberately deferred findings. Check before "fixing" something that is already understood. |
| `docs/plan/slice-N-tasks.md` | Step-by-step task breakdown for slice N, with exact schemas and test cases. |

## 2. Keep HANDOVER.md true

**Update `HANDOVER.md` in the same commit as the work it describes.** Not afterwards, not "at the
end" — a session can be cut off at any moment, and an out-of-date handover is worse than none
because the next agent trusts it.

It must always answer, for someone with zero context:
- what is finished and verified
- what is half-finished, and exactly where it stopped
- what to do next, specifically enough to start without asking
- what will bite you

## 3. How to work here

- **Work in vertical slices, in the plan's order.** Each slice ends deployable and demoable. Do not
  start slice N+1 while slice N is broken.
- **Test-first, and prove the test can fail.** Break the code, watch it go red, restore. This
  codebase has had 20+ tests that passed against broken code; see the engineering rules.
- **Commit in logical chunks and push.** The human may close their laptop at any time; unpushed
  work is lost work. Do not batch a whole slice into one commit.
- **If you are a subagent told not to push, expect your commits to reach `origin` anyway.** A
  coordinating session verifies each task and pushes it, often within a minute of your last commit.
  Three separate agents have now reported this as a possible unauthorized actor with repo access,
  after finding an "update by push" in `git reflog` they could not account for. It is expected and
  benign. Report what you committed; do not treat the remote moving as a security incident.
- **Never commit secrets.** No `config/master.key`, no `.env`, no API keys, no credentials in
  fixtures or seeds. `config/credentials.yml.enc` is fine; its key is not.
- **Never require a hidden manual step to deploy.** If a change needs a new environment variable,
  add it to `render.yaml` and `.env.example` and document it in `README.md` in the same commit.
- **Keep the app runnable.** `bin/rails test` green before every push.

### The review loop that produced this codebase

Every task so far has gone: implement → independent review → fix round → scoped re-review. The
reviews are not ceremony — they have caught a cross-tenant data path, a guest session that survived
its hotel being suspended, a throttle that would have locked out an entire hotel, and repeatedly,
tests that could not fail. **If you have subagents available, keep doing this.** If you are working
alone, review your own diff deliberately against the engineering rules before committing.

When you review (or ask for a review), the instruction that actually finds things is: *break the
code this test claims to protect, run it, and confirm it goes red.*

### Reporting

Be accurate about what you did and did not verify. "Tests pass" means you ran them. If something is
flaky, say so with the observed rate. If you could not finish, say where you stopped. A confident
wrong handover costs the next session more than an honest incomplete one.

---

## Stack, in one screen

Rails 8.0 monolith · Ruby 3.4 · PostgreSQL (one database, also backing Solid Queue/Cache/Cable — no
Redis) · Hotwire (Turbo + Stimulus) via importmap · Propshaft · Tailwind v4 (no Node build) · Rails 8
auth generator (no Devise) · Pundit · `acts_as_tenant` with `require_tenant = true` (fails closed) ·
Minitest + fixtures (no RSpec/FactoryBot) · Anthropic API behind an `Ai::Client` seam · deployed to
Render (Frankfurt) via `render.yaml`.

```bash
bin/setup                 # install, create and migrate the database, seed
bin/dev                   # run locally
bin/rails test            # unit + integration
bin/rails test:system     # browser tests (headless Chrome)
```
