# Phase 2 Follow-Up — Outstanding Issues and Deployment Runbook

Companion to `played_games_ownership_rework.md`. That doc says *what* the
rework is; this one says what is still open and exactly how to get Phase 2
onto staging and production safely.

Written 2026-09-01, against api `4323398` and client `da7783f`.

---

## 1. Where things actually stand

| | api | client |
|---|---|---|
| Last SemVer tag | `v1.0.5` = `4d56d3f` | `v1.0.5` = `da7783f` |
| `Phase-1-Deploy` tag | `4d56d3f` (same commit as `v1.0.5`) | `da7783f` (same commit as `v1.0.5`) |
| Branch head | `4323398` on `develop` | `da7783f` on `develop` |
| Unreleased work | 3 commits past `v1.0.5` (all Phase 2) | none past `v1.0.5` |

Unreleased api commits:

- `514b73a` — restores the test CORS origins as a constant (regression fix)
- `a4b3a4b` — **Phase 2**: `games` table, dual-write, backfill/verify tasks
- `4323398` — design-doc status update

Everything above is committed on `develop` in both repos. **Nothing from
Phase 1 or Phase 2 is deployed yet.**

---

## 2. Blockers — resolve before attempting any deploy

### 2.1 `v1.0.5` has no release-notes entry (blocks *both* repos)

`bin/deploy` runs `bin/check-release-notes`, and the api additionally runs
`bin/check-sibling-release`, which calls the client's checker. Right now:

```
$ cd client && bin/check-release-notes v1.0.5 develop
release-notes.html has no id="v1-0-5" section for v1.0.5 (checked at develop).
```

So a `v1.0.5` deploy aborts in either repo. A `v1-0-5` section must be added
to `client/release-notes.html` before anything ships.

Note the erase feature stays out of any user-facing notes, as always.

### 2.2 The `Phase-1-Deploy` tag cannot drive a deploy

`bin/deploy` validates any explicit tag against
`^v[0-9]+\.[0-9]+\.[0-9]+(-suffix)?$`, and the no-tag path resolves the
branch tip's tag through `ReleaseTagResolver::TAG_PATTERN`
(`/\Av\d+\.\d+\.\d+\z/`). `Phase-1-Deploy` matches neither, so:

```
bin/deploy staging Phase-1-Deploy
# Error: 'Phase-1-Deploy' is not a valid version tag (expected vX.Y.Z or vX.Y.Z-suffix)
```

It is a useful bookmark, but deploys must go through a SemVer tag. Since it
points at the same commit as `v1.0.5` in both repos, nothing is lost.

### 2.3 Release tags are lockstep across repos — the design doc is wrong about this

`played_games_ownership_rework.md`'s sequencing section says "the repos
version independently and their tags are not in lockstep." **The tooling
enforces the opposite** for real releases. From `bin/check-sibling-release`:

> Client and api are versioned in lockstep: releasing either repo under a
> real tag (`vX.Y.Z`) requires the same tag to already exist in the other
> repo, reachable from the branch being deployed, and — since release notes
> are player-facing and only live in the client — a `release-notes.html`
> section for it on the client's branch.

The check is symmetric: `client/bin/deploy` demands the api's tag too. Only
suffixed staging tags (`vX.Y.Z-suffix`) are exempt.

**Practical consequence for Phase 2:** Phase 2 changes no client code, but
shipping it still requires tagging the client at the same version with a
release-notes entry. What genuinely stays independent is *deploy order*, not
version numbers — and deploy order is what provides the expand/contract
safety, so the rework's sequencing rule still holds in substance. The doc's
wording needs correcting; see §6.

### 2.4 Work is on `develop`; deploys run from `staging` / `main`

`bin/deploy staging` deploys the `staging` branch, `production` deploys
`main`, and `check-sibling-release` requires the sibling tag to be an
*ancestor of that branch*. Tags sitting on `develop` do not satisfy it. The
merge up is a deliberate, human step — nothing here does it automatically.

---

## 3. Deployment runbook

### 3.0 The one ordering rule that matters

> **`games:backfill` must run only after the dual-write code is live.**

Migrations run at `deploy:updated`, *before* the symlink flip, so `games`
exists while the old code is still serving. If the backfill ran in that
window, any game completed between the backfill and the flip would land in
`played_games` alone and never reach `games` — a silent gap in exactly the
table Phase 3 is about to trust. Backfill is therefore a separate manual
step after the deploy reports success.

Re-running the backfill is harmless (`ON CONFLICT DO NOTHING`), so when in
doubt, run it again rather than reasoning about whether you needed to.

### 3.1 Pick a version and prepare both repos

Phase 2 is api-only in substance, so a patch bump is right. Assuming
`v1.0.6`:

```bash
# 1. Write release notes FIRST -- both repos' deploys check for them.
#    client/release-notes.html needs an id="v1-0-6" section.
#    (Cover v1.0.5's content too if that never shipped; see §2.1.)

# 2. Merge develop -> staging in BOTH repos (your call, not automated)
cd client && git checkout staging && git merge develop
cd ../api && git checkout staging && git merge develop

# 3. Tag the same version in both repos, on staging
cd ../client && git tag -a v1.0.6 -m "Release 1.0.6"
cd ../api    && git tag -a v1.0.6 -m "Release 1.0.6"

# 4. Push tags to the server remote and origin
cd ../client && git push paula-poundstone v1.0.6 && git push origin v1.0.6
cd ../api    && git push paula-poundstone v1.0.6 && git push origin v1.0.6
```

`bin/deploy` runs `bundle exec rake test` and **deletes the local tag if the
suite fails**, so expect to re-tag if that happens.

### 3.2 Deploy to staging — api first

API before client, per expand/migrate/contract: the server must accept and
store `game_id` before any client sends it. (Phase 1's client half is in
this same release, which is why the order is load-bearing.)

```bash
cd api && bin/deploy staging
```

This runs migrations (`db:migrate` at `deploy:updated`, creating `games`),
flips the symlink, restarts puma, syncs the Caddy site file, and seeds
scheduled tasks.

Then the client:

```bash
cd ../client && bin/deploy staging
```

### 3.3 Backfill staging, then verify

Only after §3.2 reports success:

```bash
ssh deploy@paula-poundstone
cd /home/deploy/staging_left_wordle_api/current
bundle exec rake games:backfill
bundle exec rake games:verify
```

`games:verify` should report `missing from games: 0` and
`status mismatches: 0`. The `games with no played_games counterpart` line is
**expected to be non-zero and to grow** — it counts games created after the
backfill, and after Phase 4 drops `user_id` it will count everything. It is
not a failure signal.

### 3.4 Soak on staging for 8–24 hours

Standard cadence. During the soak, watch for:

```bash
# Dual-write failures -- should be completely silent
journalctl -u left-wordle-api-staging --since "1 hour ago" | grep "games dual-write"
```

Any `[games dual-write]` line means the mirror is incomplete and Phase 3's
comparison would be built on sand. Investigate before promoting.

Also worth a spot check that live play lands in both tables:

```sql
-- after playing a game on staging while logged in
SELECT count(*) FROM games WHERE created_at > now() - interval '10 minutes';
```

### 3.5 Promote to production

```bash
cd api && git checkout main && git merge staging && git push paula-poundstone main
bin/deploy production

cd ../client && git checkout main && git merge staging && git push paula-poundstone main
bin/deploy production
```

Then the production backfill — again, only after the deploy succeeds:

```bash
ssh deploy@paula-poundstone
cd /home/deploy/left_wordle_api/current
bundle exec rake games:backfill
bundle exec rake games:verify
```

Production has real multi-device users, so unlike dev/staging the backfill
will genuinely collapse duplicates. Expect
`scanned > inserted` only on a re-run; on the first run they should match,
and `scanned` should equal the canonical count `games:verify` reports.

### 3.6 Things no deploy does for you

1. **Cloudflare cache rules** — `bundle exec rake 'create_cache_rules[prod]'`
   with `CF_CACHE_RULES_TOKEN` set. Not needed for Phase 2 (no asset or
   caching change), but noted so the omission is deliberate.
2. **Caddy config for the client** lives in the api repo, so it ships with
   the api deploy. The `hide-dot-files` change from `v1.0.5` (`4d56d3f`)
   goes live with this release — see §4.2 for what to verify afterwards.
3. **Cloudflare purge** is automatic on client deploy, but check the log; a
   silent failure is what makes an asset change user-visible.

### 3.7 Rollback

Phase 2 is designed to be revertible, and each layer peels back
independently:

| Situation | Action |
|---|---|
| Dual-write misbehaving, data intact | Deploy the previous tag. `games` stays; nothing reads it, so it is inert. |
| Need the table gone | `bundle exec rake 'db:migrate[22]'` rolls back migration 023 (drops `games`). Quote it — zsh globs the brackets otherwise. Verified: drops cleanly and re-applies. |
| Bad release generally | `bundle exec cap production deploy:rollback` for an immediate symlink flip — but note it does **not** roll migrations back. |

Because nothing reads `games` in Phase 2, a rollback of the code alone is
always safe: the worst case is a stale table that Phase 3 would re-backfill
anyway.

---

## 4. Outstanding issues

### 4.1 `stats_adjustments` prune has never run (production impact likely)

`scheduler:tick` registers `stats_adjustments:prune` and invokes it by name,
but `Rakefile` never loaded `lib/tasks/stats_adjustments.rake`. Every tick
raised "Don't know how to build task", which the scheduler's `rescue` logged
and swallowed. Fixed in `a4b3a4b`.

**The fix makes the task runnable; it does not undo the backlog.** The 90-day
retention has never been enforced, so the table holds every stats event ever
written. After deploying, check and prune:

```sql
SELECT count(*), min(created_at) FROM stats_adjustments;
```

```bash
bundle exec rake stats_adjustments:prune
```

Worth watching the first run — a large first delete on a live table is the
kind of thing to do deliberately rather than discover via the scheduler at
03:00.

### 4.2 Deployed web roots may still expose files now marked `export-ignore`

Client `da7783f` adds `export-ignore` for `dev/`, `manual_testing/`, and
`README.md`. `export-ignore` only affects *future* archives — it does not
remove what previous deploys already placed in the web root. After the
client deploy, confirm they are actually gone from both environments:

```bash
curl -sI https://staging.left-wordle.com/README.md | head -1
curl -sI https://left-wordle.com/README.md | head -1
curl -sI https://left-wordle.com/manual_testing/README.md | head -1
```

Anything other than 404 means a stale file needs removing from the server.

Similarly, verify the Caddy `hide-dot-files` snippet is doing its job once
the api deploy has reloaded Caddy — it was defined but never imported, so
dotfiles were served for as long as it existed:

```bash
curl -sI https://left-wordle.com/.gitattributes | head -1   # expect 403
curl -sI https://left-wordle.com/.well-known/foo | head -1  # expect 404, NOT 403
```

The second matters as much as the first: a 403 there would mean ACME renewal
and passkey paths are broken.

### 4.3 Passkey e2e spec is skipped, not passing

`client/e2e/passkey_login.spec.js` (4 tests) skips unless an API is
reachable at `LEFT_WORDLE_E2E_API_BASE_URL` (default `localhost:9377`).
`npm run test:e2e` never starts one, so they skip in normal runs.

Standing it up needs more than a port: `app.rb` reads `webauthn_origin` from
its single `config/app_config.yml`, and a local dev setup has that pointed at
the Caddy origin (`https://left-wordle.test`). WebAuthn compares it against
the *client* origin, so a ceremony driven from `http://localhost:3000` fails
on mismatch even with the port listening. Confirmed by pointing the spec at
the dev API on 9292: the gate opened, the tests ran, and all four failed on
exactly that mismatch.

The better fix is to move the spec onto the Caddy dev environment, where
client and API share one HTTPS origin as production does — retiring the
port-9377 and `credentials: 'include'` workarounds instead of documenting
them. Not urgent; the flows are covered by manual testing.

### 4.4 API contract docs are incomplete

`docs/api_interface.md` documents `/api/v1/game/start` but has **no sections
at all** for `/api/v1/game/complete`, `/api/v1/game/progress`, or any `/api/v2`
endpoint (`/history`, `/history/import`, `/profile`, the auth routes). Phase 1
added `game_id` to all of the game endpoints and only `/game/start` could be
documented in place.

This matters more from Phase 3 on, since the client/api contract rule in
`CLAUDE.md` assumes the contract is written down somewhere. Worth a
standalone docs pass.

### 4.5 Response still reports the played_games id

Deliberate, and repeated here so it is not mistaken for an oversight: every
game write responds with `played_games.game_id`, not the `games` row's
`client_game_id`. They agree for a single device; for a user on two devices
`played_games` holds two ids while `games` holds the first. Flipping the
response to the `games` row is the more correct convergence signal and is
deferred to Phase 3 along with the reads, so Phase 2 stays a true client
no-op and the revert stays clean.

### 4.6 Historical lost wins are not repaired

By decision, not omission. The backfill reproduces the canonical view
including its historical undercounts. Statistics change only from a live
completion or the user's own manual adjustment. If a user reports missing
wins, the Adjust Stats tool is the remedy — do not write a repair job.

### 4.7 Pre-existing lint offenses

`standardrb` reports 11 offenses in the api, all pre-existing and none
introduced by Phase 2 (verified by comparing against a clean tree). Mostly
`Layout/MultilineOperationIndentation` and a `Style/YAMLFileRead` in the
Rakefile. Harmless; noted so a future cleanup is not mistaken for a
regression from this work.

---

## 5. Phase 3 readiness checklist

Phase 3 is the risky one and its gate is production data. Before starting it:

- [ ] Phase 2 deployed to production and soaked
- [ ] `games:backfill` run on production, `games:verify` clean
- [ ] Zero `[games dual-write]` lines in the production log over the soak
- [ ] `stats_adjustments` backlog pruned (§4.1), so its table size is not a
      confounding variable during Phase 3 monitoring

Phase 3 then adds dual-*read* comparison logging in production, soaks until
divergence is quiet, and only then flips reads behind the
`config/app_config.yml` flag.

---

## 6. Corrections owed to the design doc

Fold these into `played_games_ownership_rework.md` when Phase 3 is written
up, so it does not keep asserting things the tooling contradicts:

1. **"The repos version independently and their tags are not in lockstep"**
   is wrong for real releases (§2.3). Replace with: release *tags* are
   lockstep and enforced by `check-sibling-release`; deploy *order* is what
   varies, and that is what expand/contract depends on.
2. Add that a release also requires a `release-notes.html` entry on the
   client, which gates the api deploy too.
3. Note that migrations run automatically at `deploy:updated` (before the
   symlink flip), which is why the backfill is a deliberate post-deploy step
   rather than something to hook into the deploy.
