# played_games Ownership Rework

The single reference for this rework: why it exists, what was decided, what
each phase built, where things stand, and how the next release ships.

State in §5 as of 2026-10-11, after `v1.0.5` and `v1.0.6` reached
production and the phase branches were rebased onto `develop`. Supersedes
`played_games_ownership_rework.md` and `phase_2_follow_up.md` (both deleted).

This is a data-model change with an API-contract surface, so it lives in
`api/docs/`, but it moves both repos: `CLAUDE.md`'s companion-repo rule
applies to every phase that touches the contract.

---

## 1. Why: the device is the identity, the user is an attribute

`played_games` (migration 007) was built as an anonymous, device-scoped
analytics table: `UNIQUE (client_device_id, date)`, no user concept.
`user_id` was bolted on later (migration 014), nullable. So the **device** is
the identity of a game and the **user** is an attribute of the row. That
inversion causes three problems.

**Security.** `client_device_id` is client-supplied (the `X-Device-ID`
header, or an import row's `device_id`) and is half the unique key, so anyone
who knows a device id can address someone else's row. Before Phase 0 an
authenticated request carrying a victim's device id reassigned and
overwrote the row; before Phase 0.5 an *anonymous* one could still poison
it. Both holes are closed in production, but by scoping code layered on the
broken model.

**Lost wins: the headline motivation.** One user, one puzzle, two devices
means two rows, and a read-time canonicalization layer
(`canonical_played_game_for`, `history_hash_for`'s collapse) referees them.
The trace before Phase 0.5:

1. User starts today's puzzle on desktop: row A, `game_status` nil.
2. User finishes on phone: row B, `game_status` WIN, then
   `apply_played_game_to_statistics!(user, puzzle_num, "WIN")`.
3. The canonical row was the earliest, A, whose status nil ≠ WIN, so the
   guard returned `:non_canonical`. **The win never counted.** No streak, no
   histogram bucket, and nothing ever retried it.

Phase 0.5 stopped the bleeding (canonical selection prefers completed rows),
but it is still a read-time patch over a write-time modeling error. The fix
is to make the duplicate unrepresentable.

**Shared devices can't be represented.** One row per device per day,
whoever is signed in, so a household sharing a tablet is outside the model.

## 2. Settled decisions (do not relitigate)

- **Authorization comes from the session, never a client-supplied id.** A
  client-minted `game_id` is exactly as forgeable as a `client_device_id`.
  It buys identity, dedup, and idempotency, and **zero** access control. No
  endpoint may ever use it to decide whether a caller may read or write a
  row; the session's `user_id` and the `(user_id, puzzle_num)` key do that.
- **A user plays a given puzzle once.** `UNIQUE (user_id, puzzle_num)`.
  Duplicates become impossible rather than reconciled.
- **No claiming of anonymous rows at signup.** Registration imports from the
  device's local storage, not pre-existing server rows (migration 014
  already said so). This is what makes dropping `played_games.user_id` safe.
- **Keep the anonymous table.** `played_games` is cheap root data for usage,
  starting-word, and country/mode analysis.
- **No sessions for anonymous users.** A session authenticates continuity,
  not legitimacy. Once the tables are split, a forged anonymous row is a
  data-quality problem in telemetry, not a security one.
- **Stats change only from a live completion or the user's own manual
  adjustment** (Tools > Adjust Stats, audited in `stats_adjustments`). No
  backfill, migration, or repair job may move a user's visible numbers, not
  even to fix a historical undercount. A user who reports missing wins uses
  the adjustment tool.

## 3. Target model

**`played_games`: pure telemetry.** Keeps the `(client_device_id, date)` key,
drops `user_id` and the transitional `game_id` entirely (a shared id would
recreate the `played_games → games → users` join and undo the privacy win),
and gains an `authenticated` boolean so the signed-in/out cut survives
without account linkage.

**`games`: new, user-owned** (migration 023):

```
games
  id              uuid PRIMARY KEY DEFAULT uuidv7()  -- server-minted surrogate
  client_game_id  uuid NOT NULL             -- client-minted UUIDv7
  user_id         uuid NOT NULL REFERENCES users ON DELETE CASCADE
  puzzle_num      integer NOT NULL
  date            date NOT NULL
  mode            text                      -- regular | hard | insane
  game_status     text                      -- WIN | FAIL | null (in progress)
  guesses         jsonb
  completed_at    timestamp
  created_at      timestamp NOT NULL DEFAULT now()
  updated_at      timestamp NOT NULL

  UNIQUE (user_id, puzzle_num)
  UNIQUE (user_id, client_game_id)
```

- **Surrogate PK, not the client id.** A client-minted global PK would give
  a forgeable value structural weight: an import carrying another user's id
  (a shared backup) would hard-fail on a PK conflict, and anyone who learned
  your ids (they're in every export) could pre-insert them to block your
  writes. Per-user uniqueness is all identity and dedup need. Old clients
  that send no id get one minted server-side.
- **Naming.** The column is `client_game_id`, parallel to
  `client_device_id`; the wire field stays `game_id`.
- **Self-healing multi-device writes.** A second device that mints its own
  id for a puzzle already started elsewhere conflicts on `(user_id,
  puzzle_num)` and becomes an update; first id wins, the server returns it,
  and the client adopts it (`_adoptGameId`).
- **Why UUIDv7.** It sorts by creation time, so imports keep true play order
  and dedup correctly across restores onto new device ids. Client clocks
  are untrusted, so the id is for identity, dedup, and ordering
  convenience only: `puzzle_num` stays authoritative for streaks and
  statistics, and server `created_at` stays the audit timestamp.

**What dies in Phase 4:** `canonical_played_game_for`, the `history_hash_for`
collapse, `owned_row_scope`, the import `RETURNING` gate, and the
`:non_canonical` meaning of the stats guard.

## 4. Phases

| Phase | What | Code | Deployed |
|---|---|---|---|
| 0 | `owned_row_scope`: authenticated writes touch only unclaimed or own rows | api `e307916` | ✅ prod, in `v1.0.4` |
| 0.5 | Anonymous updates scoped to unclaimed rows; canonical prefers completed rows | api `d10004e` | ✅ prod, in `v1.0.4` |
| 1 | Client mints, sends, and adopts `game_id`; api stores and returns it; session-death completion replay | api `2767b12` (mig. 022), client `3c67a32`, `b1b6dd2` | ✅ prod, in `v1.0.5` |
| 2 | `games` table, dual-write, `games:backfill` / `games:verify` | api `a4b3a4b` (mig. 023) | ✅ prod, in `v1.0.5`; backfilled 2026-10-11 |
| 3 | Dual-read comparison, `read_games_enabled` flag (default off) | api `2310b0c`, `a01c843` (mig. 024) | ✅ prod, in `v1.0.7`, flag off; soaking since 2026-10-17 |
| 4 | Drop `played_games.user_id`; delete canonicalization. **Irreversible.** | branch `model-redesign/phase-4` (mig. 025–026) | ❌ |

### Phase 0: ownership scoping

`owned_row_scope` scopes all three upserts (`record_game_initiation!`,
`record_game_event!`, `import_history_row!`), so a row owned by another user
matches no `ON CONFLICT DO UPDATE ... WHERE` and the write is dropped.
`import_history_row!` uses `RETURNING` to detect that and withholds the
stats application.

### Phase 0.5: interim integrity fixes

1. Anonymous updates are scoped to unclaimed rows. The cost is that a
   session expiring mid-game can no longer continue the claimed row
   anonymously. That path never applied stats anyway; Phase 1's completion
   replay replaces it.
2. Canonical selection prefers completed rows (`game_status IS NULL` sorts
   last), in both the stats guard and the history read.

### Phase 1: client-minted `game_id`

- Client mints a UUIDv7 at game start (`GameStateManager.generateUuidV7()`),
  stores it in `gameState`, writes it to the history entry, and preserves it
  through export/import (accepts `game_id` and `gameId`).
- API accepts it on `/game/start`, `/game/progress`, `/game/complete`, and
  history-import entries; validates softly (malformed is dropped, never a
  400); stores keep-first in the transitional `played_games.game_id`; and
  returns it on every game write and history row.
- Client sends it on all three calls and imports, adopts the returned id,
  and maps it from server history.
- **Session-death completion replay:** when a session dies mid-game and the
  device finishes offline, on the next login the client re-sends that
  completion, authenticated, if the server's copy is still in progress and
  carries the same `game_id`. It completes a game the server already knows,
  so it does not breach `online_play_redesign.md`'s no-merge rule.
- Contract change: api deploys first; the server tolerates the field's
  absence indefinitely.

### Phase 2: `games` table, dual-write, backfill

- Authenticated live writes and imports dual-write `played_games` (as
  before) and `games` (`ON CONFLICT (user_id, puzzle_num) DO UPDATE`).
- Merge rules are uniformly "never lose what's recorded": `client_game_id`,
  `game_status`, and `completed_at` keep-first; `guesses` longest-wins (takes
  the newest live board, survives an out-of-order retry or a guess-less
  import).
- A failed `games` write never breaks gameplay but is **logged** as
  `[games dual-write]`. A silent failure would make Phase 3's comparison lie.
- The import dual-write sits behind `owned_row_scope`, so an import aimed at
  another user's row creates no `games` row.
- `games:backfill` copies the canonical view of `played_games` with `ON
  CONFLICT DO NOTHING` (live rows always win), carrying stored ids or minting
  backdated ones with PostgreSQL 18's
  `uuidv7(coalesce(completed_at, created_at) - now())`. It reproduces
  history including historical undercounts; per §2 it moves no numbers.
- `games:verify` reports missing rows and status mismatches against the
  canonical view. Its "games with no played_games counterpart" line is
  expected to grow (games created after the backfill).
- Responses still report `played_games.game_id`, not the `games` row's id.
  They agree on one device; for two devices `games` holds the first. The
  flip is deferred to Phase 3 so Phase 2 stays a client no-op.
- Api-only. Revertible by rolling back migration 023 (see §7.7).

### Phase 3: reads cut over to `games` (shipped in `v1.0.7`, flag off)

`history_get_response` and the canonical lookup in
`apply_played_game_to_statistics!` move to `games`. Both answers are
computed on every request and compared; divergences go to a
`games_read_divergences` table (`rake games:divergences`). The
`read_games_enabled` flag in the api's per-deployment
`shared/config/app_config.yml` decides which answer is served; flipping it
is a config change and a restart, which is the revert story. With the flag
on, the response `game_id` comes from the `games` row.

The gate is **production** evidence: a week or more of quiet divergences on
real traffic (multi-device users, legacy imports, broken streak chains,
pre-history aggregates). Staging can't reproduce that diversity. A prior
full-recompute approach caused real data loss, which is why this phase gets
the paranoid treatment. Procedure: `docs/phase_3_runbook.md`.

Phase 3's *code* being written is not Phase 3 being done: the phase is
finished when the divergences have been quiet on production traffic and the
flag is on.

**As built** (migration 024):

- Divergences are recorded in a `games_read_divergences` table, not the
  log. The soak's question is "have the two reads stopped disagreeing for
  real traffic", which is a query; grepping journalctl across puma workers
  is not, and rotation loses the history the decision rests on. One row per
  disagreeing `(read_name, user_id, puzzle_num)`, bumped via `seen_count`
  on repeat rather than duplicated, plus a per-read cap, so a user reloading
  history can't bury the signal. `rake games:divergences` reports it;
  `games:clear_divergences` resets it once a cause is understood.
- **`game_id` is excluded from the history comparison, deliberately.** For a
  user who played one puzzle on two devices, the canonical `played_games`
  row may carry a different id than the `games` row, which keeps the first
  id it ever saw. That difference is expected (it's what the response flip
  below fixes), and counting it as divergence would bury the real signal.
- The stats comparison looks only at what `next_statistics_for` actually
  consumes: whether a row exists, its `game_status`, and its guess count.
  Comparing more would manufacture divergences that can't move a number.
- With the flag on, the response `game_id` also comes from the `games` row,
  so every device converges on one id. This needs no client change:
  `_adoptGameId` has taken the server's id as authoritative since Phase 1.
  But until now the server always echoed back the id the client sent, so
  adopting a *different* one is a path this phase activates for the first
  time.
- Comparison failures rescue and warn: diagnostics never take down the read
  they observe.

The full test suite passes unchanged with the flag off, which is what makes
this safe to deploy ahead of any decision to flip it.

### Phase 4: drop `user_id` (built, not merged)

Adds `authenticated` (sticky across a day), drops `played_games.user_id` and
`game_id`, deletes canonicalization, the comparison, and the backfill/verify
tasks; imports stop writing telemetry; anonymous callers get `game_id:
null`. **Migration 025 destroys every row-to-account association; only a
database restore undoes it.** Requires Phase 3's flag on in production long
enough that reverting is unthinkable, plus a verified backup. Procedure:
`docs/phase_4_runbook.md` on the branch.

## 5. Current state (2026-10-17)

**Deployed:** `v1.0.7` (Phase 3) is in production in both repos, released
2026-10-17. Staging got it the same day and production followed within
hours rather than after the usual 8–24h soak: staging doesn't get enough
traffic for a wait to tell us anything, and the flag being off means the
release changes nothing users see.

Readiness checks before merging (§7.8), all on production:
`games:verify` was clean at 1236 `games` rows against 1236 canonical
`played_games`, 0 missing, 0 status mismatches. That is 57 games written by
the dual-write since the 1179-row backfill, with no `[games dual-write]`
errors logged. The `stats_adjustments` prune removed 0 rows: the scheduler
had already enforced retention.

After deploying, on both environments: migration 024 ran,
`games:divergences` was empty, `read_games_enabled` is absent from
`shared/config/app_config.yml` (so off), and the client deploy's Cloudflare
purge succeeded. On staging, opening an unplayed archive puzzle and
finishing it ran both comparisons (history and stats canonical) with no
divergence.

**The soak (runbook §3) started 2026-10-17.** Check `rake games:divergences`
on production every few days. A week of normal traffic is the floor before
flipping `read_games_enabled`, staging first (runbook §4). Phase 3 is done
only once the flag is on in production.

**Branches:**

- `main` and `staging` in both repos are at `v1.0.7` and pushed. `develop`
  is the same, plus client `f5542dd` (the `v1.0.7` production badge), which
  is local only and goes out with the next release. The deploy's own
  marking step failed because `develop` was checked out, and it was rerun
  by hand.
- `develop` is local-only by design (the pre-push hooks allow only `main`
  and `staging`).
- `model-redesign/phase-3` is fully merged in both repos (fast-forwarded)
  and can be deleted.
- `model-redesign/phase-4` is still stacked on the old `phase-3` tip, so
  it is **behind `develop`**: api is missing "Marks Phase 3 Readiness
  Checks Complete" and this update, client is missing the `v1.0.7` release
  notes and badge. Rebase it onto `develop` before its own release (§6),
  and expect a conflict in this file: Phase 4's notes edit it too. api
  `phase-4` is two commits, "Drops played_games.user_id and Deletes
  Canonicalization" and "Adds the Phase 4 Runbook and Records It As
  Built". Client `phase-4` is one commit, "Corrects the Retry-Safety Note
  for Per-Account Import Dedup". Hashes are left out on purpose: every
  rebase changes them.
- Pre-rebase tips are kept as `backup/phase-{3,4}-pre-rebase`: tags in the
  api, branches in the client. Delete them once nothing needs comparing.
  Delete the client branches before the next `--update-refs` rebase, which
  would move them along with the phase branches.
- The local api test database follows whichever branch last ran the
  suite. `develop` now includes migration 024. After running `phase-4`
  (migrations 025–026) it must be rebuilt before `develop`'s suite runs:
  `dropdb left_wordle_api_test && createdb left_wordle_api_test`.

## 6. Branch plan

1. ✅ `v1.0.5` (Phases 1–2) shipped from `develop`.
2. ✅ Phase branches rebased onto `develop`. The conflicts were all doc
   references or Phase 4 deleting code `develop` had commented on; the "As
   built" notes for both phases are now in §4 and the old design doc is
   gone.
3. ✅ Production accumulated 57 dual-written games before Phase 3 merged
   (§5).
4. ✅ `phase-3` fast-forwarded into `develop` in both repos and released as
   `v1.0.7` (2026-10-17).
5. **Now: the Phase 3 soak**, then the flag flip (`phase_3_runbook.md`
   §3–4).
6. **Hotfixes in the meantime** go on `develop` and ship as a normal
   release. `phase-4` needs rebasing onto `develop` anyway (§5):
   ```bash
   git checkout model-redesign/phase-4
   git rebase develop
   ```
   then run the suites on `phase-4` (and rebuild the api test DB
   afterwards). `--update-refs` is no longer needed now that `phase-3` is
   merged.
7. Phase 4 follows only when its gate is met (`phase_4_runbook.md`).

## 7. Releasing `v1.0.5` (Phases 1 and 2) — done 2026-10-11

### 7.1 Before tagging

Nothing outstanding as of 2026-10-10: the stale tag is gone and the
client's `v1-0-5` release-notes section covers everything on `develop`,
committed (last addition `a6bb2e5`).

If anything else lands on `develop` before tagging, give it a release-notes
line too. The notes must be **committed before the tag is cut**; the check
reads the tagged tree, not the working tree. Keep erase out of them.

### 7.2 Rules the deploy tooling enforces

These are guardrails, not defects. Each fails the deploy loudly.

- **Release notes for the exact version.** `client/bin/deploy` checks
  `release-notes.html` in the tagged commit; the api's
  `bin/check-sibling-release` checks it on the client's branch.
- **Only SemVer tags deploy.** `^vX.Y.Z(-suffix)?$`. The `phase-*` tags are
  bookmarks.
- **Release tags are lockstep across repos.** Releasing either repo under
  `vX.Y.Z` requires the same tag in the other, reachable from the branch
  being deployed. Only suffixed staging tags are exempt. What varies between
  repos is *deploy order*, which is what expand/contract depends on.
- **Deploys come from `staging` / `main`**, and the sibling tag must be an
  ancestor of that branch. A tag on `develop` doesn't count.
- **The two answer lists match.** `bin/check-sibling-release` (both repos)
  compares the api's `db/seeds/answers.txt` with the client's
  `src/answer_list_sorted.js` at the tag (five-letter words, sorted,
  de-duplicated). The client computes remaining-answer counts from its
  copy, so a mismatch would show wrong counts. Fix by running
  `bundle exec rake client:generate_word_list` in the api. Added for
  `v1.0.5`; tags from before the client's sorted file existed (`v1.0.3`
  and earlier) fail it.
- `bin/deploy` runs the test suite and **deletes the local tag if it fails**.
  Expect to re-tag then.
- Migrations run automatically at `deploy:updated`, before the symlink flip.

### 7.3 Merge, tag, push

```bash
cd client && git checkout staging && git merge --ff-only develop
cd ../api && git checkout staging && git merge --ff-only develop

cd ../client && git tag -a v1.0.5 -m "Release 1.0.5"
cd ../api    && git tag -a v1.0.5 -m "Release 1.0.5"

cd ../client && git push paula-poundstone staging v1.0.5
cd ../api    && git push paula-poundstone staging v1.0.5
```

Push to the other three remotes as well, as usual.

### 7.4 Deploy to staging: api first

The server must accept `game_id` before any client sends it.

```bash
cd api && bin/deploy staging       # migrations 022–023, Caddy sync
cd ../client && bin/deploy staging
```

Then backfill and verify on staging:

```bash
ssh deploy@paula-poundstone
cd /home/deploy/staging_left_wordle_api/current
bundle exec rake games:backfill
bundle exec rake games:verify      # expect missing: 0, status mismatches: 0
```

### 7.5 Soak staging 8–24 hours

```bash
journalctl -u left-wordle-api-staging --since "1 hour ago" | grep "games dual-write"
```

Any line means the mirror is incomplete; investigate before promoting. Spot
check that signed-in play lands in `games`:

```sql
SELECT count(*) FROM games WHERE created_at > now() - interval '10 minutes';
```

### 7.6 Promote to production

```bash
cd api && git checkout main && git merge --ff-only staging && git push paula-poundstone main
bin/deploy production
cd ../client && git checkout main && git merge --ff-only staging && git push paula-poundstone main
bin/deploy production
```

The client `main` push also brings the remotes up from `v1.0.3`. Then
backfill production:

```bash
ssh deploy@paula-poundstone
cd /home/deploy/left_wordle_api/current
bundle exec rake games:backfill
bundle exec rake games:verify
```

On the first run `scanned` should equal `inserted` and the canonical count
`games:verify` reports. Production has real multi-device users, so this is
where duplicates genuinely collapse.

### 7.7 After deploying

1. **Prune `stats_adjustments`.** The scheduler's prune never ran before
   `a4b3a4b` (its rake file wasn't loaded), so the 90-day retention has
   never been enforced. Do the first, large delete deliberately:
   ```sql
   SELECT count(*), min(created_at) FROM stats_adjustments;
   ```
   ```bash
   bundle exec rake stats_adjustments:prune
   ```
2. **Confirm stale files are gone.** `export-ignore` only affects future
   archives:
   ```bash
   curl -sI https://staging.left-wordle.com/README.md | head -1          # 404
   curl -sI https://left-wordle.com/README.md | head -1                  # 404
   curl -sI https://left-wordle.com/manual_testing/README.md | head -1   # 404
   ```
3. **Confirm Caddy's `hide-dot-files`** (defined but never imported before
   `4d56d3f`):
   ```bash
   curl -sI https://left-wordle.com/.gitattributes | head -1    # 403
   curl -sI https://left-wordle.com/.well-known/foo | head -1   # 404, NOT 403
   ```
   A 403 on the second means ACME renewal and passkey paths are broken.
4. **Check the client deploy log** for the automatic Cloudflare purge.
   Cache rules aren't changed by this release.

**Rollback:**

| Situation | Action |
|---|---|
| Dual-write misbehaving, data intact | Deploy the previous tag. Nothing reads `games`, so it's inert. |
| Need the table gone | `bundle exec rake 'db:migrate[22]'` (quote it for zsh). Drops `games` cleanly. |
| Bad release generally | `bundle exec cap production deploy:rollback`. Does **not** roll back migrations. |

### 7.8 Phase 3 readiness

- [x] `v1.0.5` in production (2026-10-11)
- [x] `games:backfill` run on production, `games:verify` clean (2026-10-11)
- [x] Production has run long enough to accumulate games written by the
      dual-write (2026-10-17: 57 new games since the backfill)
- [x] Zero `[games dual-write]` lines in production over that time
      (2026-10-17). Run it as root or with `sudo` — `deploy` isn't in
      `systemd-journal`, so it sees no unit logs and the count means nothing:
      `sudo journalctl -u left-wordle-api --since "2026-10-11" | grep "games dual-write"`
- [x] `games:verify` still clean on production just before merging
      (2026-10-17: 1236 / 1236, 0 missing, 0 mismatches)
- [x] `stats_adjustments` backlog pruned (2026-10-17: 0 rows — the
      scheduler had already enforced retention since `v1.0.5`)

## 8. Open items

- **Passkey e2e spec is skipped, not passing.**
  `client/e2e/passkey_login.spec.js` needs an API at
  `LEFT_WORDLE_E2E_API_BASE_URL`, and WebAuthn's origin check fails from
  `localhost:3000` even when one is up. Better fix: run it on the Caddy dev
  environment, where client and API share an origin. Not urgent.
- **`api_interface.md` is incomplete.** No sections for `/game/complete`,
  `/game/progress`, or any `/api/v2` endpoint.
- **11 pre-existing `standardrb` offenses** in the api, none from this work.
- **Retire the server's remaining-count endpoints** in a later release:
  `POST /api/v1/game/remaining_counts` and `return_remaining_count` on
  `/api/v1/game/guess`. The client stopped calling them in `v1.0.5`, but
  browsers on older code still do for a while.
- **The `answers` table is unused at runtime** since `611ec8b`; the rake
  tasks still write it. It could be dropped, and `legal_words` could move to
  its checked-in file the same way (check production's table against
  `db/seeds/legal_words.txt` first).
- **Missed-days streak preference** (deferred from `v1.0.5`): changes the
  streak rule in `next_statistics_for`. Unblocked. Better shipped after the
  Phase 3 flag flip than during the soak, so a stats change can't be
  confused with a read divergence. Design:
  `client/docs/missed_days_do_not_end_streaks.md`.
- **`played_games` has no retention policy.** After Phase 4 it's anonymous,
  so keeping it is fine privacy-wise, but it grows forever.

## Cross-references

- `client/docs/online_play_redesign.md`: the offline/online design this
  composes with. Its "one live writer" assumption is partly superseded:
  races between devices are settled by `UNIQUE (user_id, puzzle_num)` at
  write time.
- `client/docs/migration_rethink.md`: the preserve-information principle and
  the recompute data-loss history behind Phase 3's caution.
- `api/docs/database.md`, `api/docs/api_interface.md`: update alongside the
  phases that change schema and contract.
