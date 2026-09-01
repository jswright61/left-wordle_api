# Phase 4 Runbook — The Irreversible One

Companion to `ownership_rework.md` and `phase_3_runbook.md`.

Written 2026-09-01, against branch `model-redesign/phase-4`.

---

## 0. Read this before merging anything

Migration 025 drops `played_games.user_id`. **Every row-to-account
association is destroyed, permanently.** The `down` block recreates the
columns; nothing recreates the values. There is no redeploy, no config flip,
and no backup-free path that undoes it.

That is not a defect — it is the privacy win the whole rework exists for.
But it means Phase 4 has a hard prerequisite that no test can check for you:

> `games` must have been serving reads in **production**, with
> `read_games_enabled: true`, long enough that reverting to `played_games`
> reads is off the table.

At the time of writing, none of Phases 1–3 are deployed and production is
still on `v1.0.4`. Phase 4 exists as code on a stacked branch so the work is
done; merging it toward a release now would skip every gate the previous
three phases were built to provide.

**Checklist before this branch goes anywhere near `develop`:**

- [ ] Phase 2 deployed to production, `games:backfill` run, `games:verify` clean
- [ ] Phase 3 deployed, divergence table quiet on real production traffic
- [ ] `read_games_enabled: true` in production, and left on
- [ ] Enough time on flipped reads that going back is genuinely unthinkable
- [ ] A database backup you have actually verified you can restore

---

## 1. What changes

### Schema (migrations 025, 026)

| Change | Reversible? |
|---|---|
| `played_games.authenticated` added, backfilled from `user_id IS NOT NULL` | yes |
| `played_games.user_id` dropped | **no — data destroyed** |
| `played_games.game_id` dropped | **no — data destroyed** |
| `games_read_divergences` dropped | yes (it is only evidence) |

026 is deliberately separate from 025: dropping the divergence table is
housekeeping and safe whenever, while 025 is the irreversible step.

### Behavior

- `played_games` becomes what it was originally built as: anonymous,
  per-device, per-day telemetry. Two accounts sharing a device write one row
  per day between them, which is the intended shape — it records that the
  device played, not who.
- `authenticated` is sticky across a day, so it describes the day rather
  than whichever request landed last.
- Imports write only `games`. See the design doc's "As built" for why
  reconstructing telemetry from an import is worse than not having it.
- Anonymous callers get `game_id: null`. The client ignores null and keeps
  its own id, so this needs no client release to be safe.

### Deleted

`owned_row_scope`, `canonical_played_game_for`, the history collapse, the
import `RETURNING` gate, the Phase 3 dual-read comparison and its flag, the
`games_read_divergences` model, and the `games:backfill` / `games:verify`
rake tasks.

---

## 2. Deploy

Ordinary release mechanics (see `ownership_rework.md` §7), with two
differences:

1. **Take and verify a database backup first.** This is the only phase where
   that sentence is load-bearing.
2. **Deploy api-only if you can.** The client needs no change for Phase 4;
   the one client commit on this branch is a corrected comment. If a client
   release is bundled anyway, order is still api-first.

Migrations run automatically at `deploy:updated`. On a table the size of
`played_games`, `ALTER TABLE ... DROP COLUMN` is a catalog operation and
fast — Postgres does not rewrite the table — but the `authenticated`
backfill before it is a full-table `UPDATE`. Check the row count and expect
that to take proportional time with the table locked.

```sql
SELECT count(*) FROM played_games;
```

---

## 3. After deploying

```sql
-- authenticated should match what user_id used to say
SELECT authenticated, count(*) FROM played_games GROUP BY 1;

-- the join path is gone
\d played_games
```

Then the behavior worth confirming by hand, since no automated test can see
production data:

- A signed-in player's history and stats are unchanged from before the
  deploy.
- A completed game still moves the numbers exactly once.
- An anonymous device still produces telemetry rows, now with
  `authenticated = false`.

`phase_3_runbook.md`'s divergence tooling is gone at this point, so there is
no automated comparison left. That is the trade: the old read no longer
exists to disagree.

---

## 4. If something is wrong afterwards

Redeploying the previous release restores the **code** but not the dropped
columns. The recovery path is a database restore, which is why §0 asks for a
verified backup rather than an assumed one.

`games` is unaffected by 025 — it never had a dependency on
`played_games.user_id` — so account data (history, stats, game ids) is not
at risk from this migration. What is destroyed is only the ability to say
which *telemetry* row belonged to which account, which is the intended
outcome.

---

## 5. What is left after this

The rework is complete. Worth noting for whoever comes next:

- `played_games` has no retention policy. It is now genuinely anonymous, so
  it can be kept indefinitely without a privacy argument — but it grows
  forever and nothing prunes it.
- `stats_adjustments` does have a prune, which only started working in Phase
  2 (`ownership_rework.md` §7.7). Check its size.
- The `authenticated` boolean is the only analysis dimension that survived
  the split. If a future question needs more, it has to be added to
  telemetry deliberately — the account join is gone for good.
