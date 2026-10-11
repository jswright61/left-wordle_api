# Phase 3 Runbook — Dual-Read Soak and the Read Cutover

Companion to `ownership_rework.md`.
Phase 3 is the phase that can move someone's statistics, so its gate is
production evidence rather than a passing test suite.

Written 2026-09-01, against api `model-redesign/phase-3`.

---

## 1. What Phase 3 actually is

Two reads move from `played_games` to `games`:

| Read | Today | After |
|---|---|---|
| `history_get_response` | all rows + `history_hash_for`'s collapse | one `games` row per puzzle, no collapse |
| canonical row in `apply_played_game_to_statistics!` | `canonical_played_game_for` | the `games` row |

Both are now computed **both ways on every request** and compared.
`read_games_enabled` decides which answer is served. It defaults off, so
deploying this changes nothing a user sees — it only starts collecting
evidence.

The stats blob, the anchor/contiguity rule, and every other part of how
statistics are derived are untouched. Only where the canonical row comes
from moves.

**Phase 3 is not finished when the code ships.** It is finished when the
divergence table has been quiet on real production traffic and the flag is
on. Those are separate events, potentially weeks apart.

---

## 2. Deploy (nothing user-visible)

Phase 3 rides a normal release. Phase 2 must already be in production and
soaked first — see `ownership_rework.md` §7.8.

1. Merge `model-redesign/phase-3` into `develop`, then `develop` into
   `staging`, in both repos.
2. Tag both repos with the same `vX.Y.Z` and write the client's
   release-notes section. Player-facing content is "nothing you can see";
   the honest note is a housekeeping line, not silence.
3. `bin/deploy staging` (api first), then the client.
4. Migration 024 runs automatically and creates `games_read_divergences`.
5. Confirm the flag is **off** — it is unless `read_games_enabled: true` is
   set in that environment's `config/app_config.yml`, which it should not be
   yet.

Nothing else to do. The comparison starts running on the next request.

---

## 3. The soak

### 3.1 What you are waiting for

```bash
cd /home/deploy/left_wordle_api/current
bundle exec rake games:divergences
```

```
No read divergences recorded. (This is the result Phase 3 is waiting for.)
```

That output, after enough production traffic that real accounts have loaded
history and finished games, is the go signal. How long is a judgement call,
but it must cover the data diversity staging cannot reproduce:
multi-device users, legacy imports, broken streak chains, and the
pre-history aggregate totals `statsDiscrepancyAfterPush` exists to catch.
A week of normal traffic is a reasonable floor; a quiet weekend is not.

Check staging too, but do not mistake it for the verification.

### 3.2 Reading a divergence

Each row names the read, the account, the puzzle, what differed, and what
each side said:

```
history   user=… puzzle=1886  seen=3x  game_status
    played_games: {"game_status" => "WIN", …}
    games:        {"game_status" => nil, …}
```

`detail` is either a comma-separated list of differing fields, or
`missing_in_games` / `missing_in_played_games`.

Rows are deduplicated per `(read_name, user_id, puzzle_num)` and bumped via
`seen_count`, so a count of 5 means five distinct disagreements, not five
page loads.

### 3.3 What each kind means

| `detail` | Likely cause | Severity |
|---|---|---|
| `missing_in_games` | Backfill never covered this row, or the dual-write failed for it | **Stop.** Re-run `games:backfill`, then investigate why the dual-write missed it |
| `missing_in_played_games` | A `games` row with no counterpart — expected only after Phase 4 drops `user_id` | Investigate; unexpected now |
| `game_status` | The two stores disagree about a result | **Stop.** This is the one that can move someone's numbers |
| `guess_count` | Out-of-order arrival: `played_games` overwrites guesses unconditionally, `games` keeps the longest | Low. Affects only a histogram bucket, and `games` holds the more complete board |
| `guesses` | Same cause, seen through the history read | Low, same reasoning |
| `date`, `mode` | A write path disagrees about metadata | Investigate; should not happen |

`game_id` differences are **not** recorded, deliberately: a multi-device
user's canonical `played_games` row can legitimately carry a different id
than the `games` row, and counting that would bury everything above.

### 3.4 If it is not quiet

Fix the cause, then `rake games:clear_divergences` and start the window
again. Clearing is a reset of the signal, not a resolution — a backlog you
have to explain every time is worse than an empty table.

`games:verify` (Phase 2) is the coarser companion: it compares the whole
`games` table against the canonical view without needing anyone to load a
page, so it catches gaps the soak has not happened to touch yet.

---

## 4. The flip

Once the table has been quiet:

1. Flip staging first. Add to that environment's
   `shared/config/app_config.yml`:
   ```yaml
   read_games_enabled: true
   ```
2. Restart puma: `sudo systemctl restart left-wordle-api-staging`.
   **This is a config change and a restart, not a deploy** — which is
   exactly why the revert is cheap.
3. Work through the "Reading Game Data From the New Store" tasks in the
   client's `things-to-test-tasks.html`. They capture your stats before the
   flip and compare after, which is the only check that matters: every
   number identical.
4. Leave staging flipped for a day or two, then do the same on production
   (`left-wordle-api`, `/home/deploy/left_wordle_api/shared/config/`).

Keep watching `games:divergences` after the flip. The comparison still runs
— it is now telling you whether the *old* read would have disagreed with
what you are serving.

### Revert

Remove the line (or set it to `false`) and restart. No deploy, no
migration, no data change. The `games` table keeps being written either way,
so flipping back and forth is safe.

---

## 5. Known and accepted

- **The comparison doubles the read work** on history and on every
  completion. That is the price of the evidence and it goes away in Phase 4
  when the old read is deleted. If it shows up in latency, the flag can go
  on sooner and the comparison can be removed early — but then the evidence
  stops, so prefer paying the cost.
- **`_adoptGameId` (client) has no automated coverage.** Until the flag goes
  on, the server always echoed back the id the client sent, so adopting a
  *different* one is a path this phase activates for the first time. It is
  covered by the two-device task in `things-to-test-tasks.html`, not by
  tests — standing up a custom-element harness for six lines would be more
  fragile than the code it tested.
- **Divergence rows are not pruned automatically.** They are bounded by
  distinct `(read, user, puzzle)` combinations, so a healthy system writes
  none. If one ever grows large, that is itself the finding.

---

## 6. Then Phase 4

Only after the flag has been on in production long enough that reverting is
off the table. Phase 4 drops `played_games.user_id`, deletes
`canonical_played_game_for`, the `history_hash_for` collapse, the
`:non_canonical` branch, `owned_row_scope`, and the import `RETURNING`
gate — and with them the dual-read comparison and this table.

That phase is the one that is **not** independently revertible: dropping
`user_id` destroys the row↔account mapping, which is the privacy win it
exists for.
