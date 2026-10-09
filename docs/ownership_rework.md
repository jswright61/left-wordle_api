# played_games Ownership Rework

The single reference for this rework: why it exists, what was decided, what
each phase built, where things stand, and how the next release ships.

State in §5 verified 2026-10-09 against all four remotes of both repos and
the server's deployed `REVISION` files. Supersedes
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
| 1 | Client mints, sends, and adopts `game_id`; api stores and returns it; session-death completion replay | api `2767b12` (mig. 022), client `3c67a32`, `b1b6dd2` | ❌ on `develop`, ships in `v1.0.5` |
| 2 | `games` table, dual-write, `games:backfill` / `games:verify` | api `a4b3a4b` (mig. 023) | ❌ on `develop`, ships in `v1.0.5` |
| 3 | Dual-read comparison, `read_games_enabled` flag (default off) | branch `model-redesign/phase-3` (mig. 024) | ❌ |
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

### Phase 3: reads cut over to `games` (built, not merged)

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
the paranoid treatment. Procedure: `docs/phase_3_runbook.md` on the branch.

### Phase 4: drop `user_id` (built, not merged)

Adds `authenticated` (sticky across a day), drops `played_games.user_id` and
`game_id`, deletes canonicalization, the comparison, and the backfill/verify
tasks; imports stop writing telemetry; anonymous callers get `game_id:
null`. **Migration 025 destroys every row-to-account association; only a
database restore undoes it.** Requires Phase 3's flag on in production long
enough that reverting is unthinkable, plus a verified backup. Procedure:
`docs/phase_4_runbook.md` on the branch.

## 5. Current state (verified 2026-10-09)

**Deployed** (from each stack's `current/REVISION` on `paula-poundstone`):

| Stack | Release | Commit | Deployed |
|---|---|---|---|
| api prod | `v1.0.4` | `462ed01` | 2026-08-31 21:13 |
| api staging | `v1.0.4` | `462ed01` | 2026-08-31 13:44 |
| client prod | `v1.0.4` | `01b288d` | 2026-08-31 21:27 |
| client staging | `v1.0.4` | `01b288d` | 2026-08-31 13:43 |

**Remotes** (chris-rock, codeberg, origin, paula-poundstone agree):

- Latest release tag `v1.0.4` in both repos, on the deployed commits. No
  `v1.0.5` on any remote.
- api `main` and `staging` are at `v1.0.4`. Client `staging` is at `v1.0.4`,
  but client **`main` is still at `v1.0.3`** (`aace4e0`): prod was deployed
  from the tag, and `main` was never pushed. Local client `main` is at
  `v1.0.4`, so pushing it at the next prod deploy brings the remotes in line.
- Bookmark tags already pushed: `Phase-1-Deploy` (api) and
  `phase-1-complete` (both). Harmless, since `bin/deploy` rejects non-SemVer
  tags.

**Local:**

- `develop` in both repos holds Phases 1–2 (`phase-2-release-candidate`).
  Client `develop` adds one commit since: `46cb56c`, the stats checker
  call to action.
- Local `staging` in both repos holds an unpushed Phase 1-only merge. Local
  `main` and `staging` are both ancestors of `develop`, so the release merges
  are fast-forwards.
- Stale **local** api tag `v1.0.5` on `4d56d3f` must be deleted before
  re-tagging (§7.1).
- `model-redesign/phase-3` and `phase-4` (both repos, stacked, never pushed).

## 6. Branch plan

1. `develop` → `staging` → `main` ships `v1.0.5` (Phases 1–2). Code not ready
   for `v1.0.5` lives on the matching `model-redesign/phase-N` branch, never
   on `develop`.
2. After `v1.0.5` is on `main`, rebase the phase branches onto `develop`.
   They are stacked, so one rebase run from `phase-4` with
   `git rebase --update-refs develop` moves both. In the client, the
   stats-checker commit cherry-picked onto both branches drops out
   automatically as already applied.
3. The rebase will conflict where the branches edit the deleted design doc.
   Resolve by moving their "As built" notes into §4 of this doc and pointing
   `phase_3_runbook.md` / `phase_4_runbook.md` here instead of at the deleted
   docs.
4. Merge `phase-3` into `develop`, test locally, then release it through
   staging and prod like any other release (`phase_3_runbook.md`).
5. Phase 4 follows only when its gate is met.

## 7. Releasing `v1.0.5` (Phases 1 and 2)

### 7.1 Before tagging

```bash
cd api && git tag -d v1.0.5    # stale local tag on 4d56d3f; no remote has it
```

- Client `release-notes.html` already has a `v1-0-5` section. It doesn't yet
  mention the stats checker change (`46cb56c`), which ships in this release
  too. The notes must be **committed before the tag is cut**; the check
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

- [ ] `v1.0.5` in production and soaked
- [ ] `games:backfill` run on production, `games:verify` clean
- [ ] Zero `[games dual-write]` lines in production over the soak
- [ ] `stats_adjustments` backlog pruned

## 8. Open items

- **Passkey e2e spec is skipped, not passing.**
  `client/e2e/passkey_login.spec.js` needs an API at
  `LEFT_WORDLE_E2E_API_BASE_URL`, and WebAuthn's origin check fails from
  `localhost:3000` even when one is up. Better fix: run it on the Caddy dev
  environment, where client and API share an origin. Not urgent.
- **`api_interface.md` is incomplete.** No sections for `/game/complete`,
  `/game/progress`, or any `/api/v2` endpoint.
- **11 pre-existing `standardrb` offenses** in the api, none from this work.
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
