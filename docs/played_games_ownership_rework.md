# played_games Ownership Rework

Status: Phase 0 complete (api `e307916`). Phase 0.5 complete (api
`d10004e`). Phase 1: client minting done (client `3c67a32`), api
accept/store/return done (api `2767b12`, migration 022); the client-side
send/adopt work and the completion replay remain. Phases 2–4 below are
designed but not built.

This is a data-model change with an API-contract surface, so it lives in
`api/docs/`, but it moves both repos: `CLAUDE.md`'s companion-repo rule
applies to every phase that touches the contract. It partly supersedes the
"one live writer" assumption in `client/docs/online_play_redesign.md` (see
that doc's pointer back here): once games are keyed by `(user_id,
puzzle_num)`, multi-device races are resolved at write time by the database,
not avoided by mode discipline alone.

## The problem: the device is the identity, the user is an attribute

`played_games` (migration `007_create_played_games.rb`) was built as an
anonymous, device-scoped analytics table: `UNIQUE (client_device_id, date)`,
no user concept at all. `user_id` was bolted on later (migration
`014_add_user_id_to_played_games.rb`), nullable, explicitly documented as
"anonymous play keeps inserting with user_id: nil exactly as today."

So today the **device** is the identity of a game and the **user** is an
attribute of the row. That inversion has three consequences:

### 1. Security — fixed in Phase 0

`client_device_id` is client-supplied (the `X-Device-ID` header, or an import
row's `device_id` field) and is half the table's unique key, so any caller
who knows a device id can address someone else's row. Before Phase 0, the
live-play upserts made that a full takeover: `record_game_initiation!` and
`record_game_event!` set `user_id` from `coalesce(excluded, existing)`, so an
authenticated request carrying a victim's device id and date reassigned the
row and overwrote its contents. Closed by `owned_row_scope` (see Phase 0
below).

Phase 0 left a second door open: it scoped only *authenticated* writes, so
an **anonymous** request with a victim's device id could still overwrite a
claimed row's `guesses`/`mode`/`puzzle_num` and set its `game_status` —
poisoning the canonical row so the owner's real completion bounced as
`:non_canonical`. Closed by Phase 0.5 (see below). The model that made both
possible is what this rework removes.

### 2. Data loss — the headline motivation (bleeding stopped in Phase 0.5)

Because the key is per-device, one user playing one puzzle on two devices
produces **two rows**. The read side patches over this with a
canonicalization layer:

- `history_hash_for` (app.rb) collapses rows per `puzzle_num`, first row in
  canonical order wins.
- `canonical_played_game_for` (app.rb) declares one row per
  `(user_id, puzzle_num)` canonical — before Phase 0.5, simply the earliest
  by `(created_at, id)`.
- `apply_played_game_to_statistics!` (app.rb) refuses to count a completion
  unless the canonical row's `game_status` matches the one being applied:
  `next :non_canonical unless canonical && canonical.game_status == game_status`

The failure trace as it stood before Phase 0.5, verified against the code:

1. Logged-in user starts today's puzzle on desktop. `record_game_initiation!`
   inserts row A (`client_device_id` = desktop, `game_status` nil,
   `user_id` set).
2. Same user finishes the puzzle on their phone. `record_game_completion!`
   inserts row B (`client_device_id` = phone, `game_status` "WIN") and calls
   `apply_played_game_to_statistics!(user, puzzle_num, "WIN")`.
3. `canonical_played_game_for` orders by `(created_at, id)` and returns row A
   — the earlier, unfinished desktop row.
4. Row A's `game_status` is nil, which does not equal "WIN", so the guard
   returns `:non_canonical`. **The win never counts.** No streak, no
   histogram bucket, no games-played increment — and nothing ever retries it.

Phase 0.5 stops the bleeding (canonical selection now prefers completed
rows, so the phone's WIN wins), but canonicalization remains a read-time
patch over a write-time modeling error. The real fix is to make the
duplicate unrepresentable, not to referee it better.

### 3. Two users on one device can't be represented at all

`UNIQUE (client_device_id, date)` allows exactly one row per device per day,
whoever is logged in. A household sharing a tablet is simply outside the
model.

## Decisions (settled — do not relitigate)

**Authorization comes from the session, never from any client-supplied id.**
A user owns their rows, full stop; the session proves who is asking. This is
the easiest thing to get wrong later, so to be explicit: a client-minted
`game_id` is exactly as forgeable as a `client_device_id`. It buys identity,
dedup, and idempotency — and **zero** access control. No future endpoint may
ever use `game_id` (or any other client-minted value) to decide whether a
caller may read or write a row; the session's `user_id` decides that, and the
unique key `(user_id, puzzle_num)` scopes every write to the caller's own
data by construction.

**A user plays a given puzzle once.** `UNIQUE (user_id, puzzle_num)` on the
new table. Duplicates become impossible rather than reconciled.

**No claiming of anonymous rows at signup.** Registration imports from the
device's local storage (`syncHistoryEntries` → `import_history_row!`), not
from pre-existing server rows. Migration 014 already declared "historical
pre-link rows are not retroactively claimed," and nothing depends on
claiming. This is what makes it safe to drop `user_id` from `played_games`
at the end.

**Keep the anonymous table.** `played_games` is cheap root data for usage
patterns, starting-word analysis, country/mode breakdowns, and analysis not
yet imagined. Querying raw rows beats writing bespoke telemetry after the
fact.

**No sessions for anonymous users.** A session authenticates *continuity*,
not *legitimacy* — an attacker just requests N sessions, so anonymous
sessions buy no integrity. Once the tables are split, a forged anonymous row
is a data-quality problem, not a security one, and data-quality noise in a
telemetry table is an acceptable cost.

**Stats never change except when the user completes a current game.** Users
watch their stats closely, and the ones who care, care a lot. No backfill,
migration, or repair job may ever move a user's visible numbers — not even
to "fix" a historical undercount. The two sanctioned paths are the live
completion event (`apply_played_game_to_statistics!`) and the user's own
manual adjustment (Tools > Adjust Stats, audited through
`stats_adjustments`). If a user spots something amiss from a historical
bug, the adjustment tool is their remedy. This principle decides the
backfill-repair question below and constrains every future migration.

## Target model

### `played_games` — pure telemetry

Keeps the name and the `(client_device_id, date)` key. **Drops `user_id`
entirely.** Written by every client, authenticated or not, exactly as the
anonymous path works today. Dropping the FK is a privacy win: telemetry can
no longer be joined to accounts, so analysis over it is analysis over
devices, never over people.

Final telemetry columns, decided:

- **No `game_id`.** A shared id on both tables re-creates the join path
  `played_games → games → users` and gives back part of the privacy win —
  and the no-join property is the point of dropping the FK. Phase 1 adds a
  *transitional* `played_games.game_id` column so ids accumulate for the
  Phase 2 backfill to carry over; Phase 4 drops it along with `user_id`.
- **Add `authenticated` (boolean)** so the logged-in/logged-out cut stays
  available for analysis without any account linkage.

### `games` — new, user-owned

```
games
  id              uuid PRIMARY KEY DEFAULT uuidv7()  -- server-minted surrogate
  client_game_id  uuid NOT NULL             -- client-minted UUIDv7 (see below)
  user_id         uuid NOT NULL REFERENCES users ON DELETE CASCADE
  puzzle_num      integer NOT NULL
  date            date NOT NULL
  mode            text                      -- regular | hard | insane
  game_status     text                      -- WIN | FAIL | null (in progress)
  guesses         jsonb
  completed_at    timestamp
  created_at      timestamp NOT NULL DEFAULT now()   -- server clock, audit
  updated_at      timestamp NOT NULL

  UNIQUE (user_id, puzzle_num)
  UNIQUE (user_id, client_game_id)
```

No device column in the identity. The device a game was played on may be
recorded as a plain attribute if it proves useful, but it participates in no
key and no authorization decision.

**Why a surrogate PK instead of the client-minted id.** Making a
client-minted value the *global* primary key quietly gives it structural
weight across all users — violating this doc's own "a client-minted id buys
zero access control" principle. Concretely: an import carrying another
user's id (a copied or shared backup — a real support scenario) would hit a
PK conflict that the `(user_id, puzzle_num)` upsert clause doesn't handle,
turning a self-healing write into a hard error; and anyone who learns your
ids (they're in every exported backup) could pre-insert them under their own
account and block your writes. Per-user uniqueness — `UNIQUE (user_id,
client_game_id)` — is all that identity, dedup, and ordering ever needed;
the server mints its own PK. When a request arrives without a client id (old
clients), the server mints the `client_game_id` too. (Column naming —
`client_game_id` vs `client_uuid` — and any remaining questions about the
client-minted id's exact role are deliberately left open until the Phase 2
migration is written; the wire field stays `game_id` regardless, matching
what client `3c67a32` already stores.)

**Self-healing multi-device writes.** If a second device misses the
in-progress state and mints its own id for a puzzle the user already started
elsewhere, its insert conflicts on `(user_id, puzzle_num)` and becomes an
update of the existing row — first id wins. The server returns the winning
`game_id` in the response so the client adopts it and converges. Compare the
current model, where that same situation silently creates the duplicate row
that loses wins.

### Why UUIDv7, and its limits

UUIDv7 sorts by creation time. That means:

- **Imports keep true play order.** Today a year of imported history all
  lands with the same server `created_at`, collapsing play order to
  server-arrival order; a v7 `game_id` minted at play time preserves the
  real sequence.
- **Import becomes idempotent across devices and restores.** The current
  `(client_device_id, date)` dedup is wrong across a restore onto a new
  device id; a stable per-game id dedups correctly no matter where the
  backup lands.

Caveat: client clocks are untrusted, so `game_id` is for identity, dedup,
and *ordering convenience* only. `puzzle_num` stays authoritative for
streaks and statistics (the anchor/contiguity rule in
`apply_played_game_to_statistics!` is unchanged by this rework), and the
server-side `created_at` stays as the audit timestamp.

### What dies with the old model

- `canonical_played_game_for` — no duplicates to canonicalize.
- `history_hash_for`'s first-arrival-wins collapse — `UNIQUE (user_id,
  puzzle_num)` guarantees one row per key.
- The `:non_canonical` branch of `apply_played_game_to_statistics!` — and
  with it the lost-win bug traced above.
- `owned_row_scope` — the Phase 0/0.5 scoping was scaffolding to close live
  holes in the old model; once authenticated writes target `games` (where
  ownership is structural) and `played_games` has no `user_id`, there is
  nothing left to scope.
- `import_history_row!`'s RETURNING-based stats gate — imports upsert into
  `games` keyed by the caller's own `user_id`, so "someone else's row" can
  no longer be addressed at all.

## Status — done, do not redo

### Phase 0 — ownership scoping (api `e307916`, complete)

`owned_row_scope` scopes all three upserts (`record_game_initiation!`,
`record_game_event!`, `import_history_row!`) so an authenticated write only
touches a row that is unclaimed or already the caller's; a row belonging to
a different user matches no `ON CONFLICT DO UPDATE ... WHERE`, so the write
is dropped rather than applied. `import_history_row!` uses `RETURNING` to
detect the suppressed case and withholds the stats application. Phase 0
left anonymous writes unscoped to preserve the expired-session-mid-game
flow; Phase 0.5 revisited that trade.

### Phase 0.5 — interim integrity fixes (api `d10004e`, complete)

Two live holes the phasing would otherwise have left open until Phase 3/4,
both fixed in code that dies with canonicalization in Phase 4:

1. **Anonymous updates are scoped to unclaimed rows.** An anonymous request
   carrying a claimed row's device id and date could overwrite its
   `guesses`/`mode`/`puzzle_num` and set `game_status`, poisoning the
   canonical row so the owner's real completion bounced as
   `:non_canonical`. `owned_row_scope` now scopes every update; anonymous
   telemetry still flows to unclaimed rows. The cost is the
   session-expires-mid-game continuation (those anonymous beats at a
   claimed row are dropped) — it never applied statistics anyway, and the
   completion replay in Phase 1 below is its real replacement.
2. **Canonical selection prefers completed rows** (`game_status IS NULL`
   sorts last, arrival order breaks ties), in both
   `canonical_played_game_for` and the history read, so stats and history
   surface the same row. This stops the ongoing start-on-desktop
   finish-on-phone win loss now rather than after the Phase 3 soak.

### Phase 1 — client-side game_id (client `3c67a32`, partial)

The client mints a UUIDv7 `game_id` when a game starts
(`GameStateManager.generateUuidV7()` in `wordle.js`), stores it in
`gameState` (`SCHEMA.gameState.gameId` in `storage-controller.js`), writes
it onto the completed history entry, and preserves it through export/import
(`toolsmenu.js` accepts both `game_id` and `gameId` spellings; import
preserves ids, never derives them). Ids are accumulating in local storage
now, ahead of the server being able to store them.

The api half is done (api `2767b12`, migration 022): `game_id` is accepted
on `/game/start`, `/game/progress`, `/game/complete`, and history-import
entries; validated softly (a malformed value is dropped like a malformed
device id, never a 400); stored keep-first in the transitional
`played_games.game_id` column; and returned — every game write responds
with the stored id via `RETURNING`, and history rows include `game_id`.

Not yet done (client): sending the id on those calls, adopting the returned
winner, mapping `game_id` from server history rows
(`serverHistoryToLocalHistory` still maps `game_id: null`), and the
completion replay below.

Known gap: per `online_play_redesign.md`, online devices don't write game
data to local storage, so their games get no locally-recorded id (the
history-entry code in `wordle.js` notes this — "those ids will come from the
server once it stores them"). Phase 1's completion closes this: once the
server stores and returns `game_id`, online devices get theirs from the
server's copy.

## Remaining phases

### Phase 1 (finish) — send and store game_id

Client sends `game_id` on `POST /api/v1/game/start`, `/game/progress`,
`/game/complete`, and in each `POST /api/v2/history/import` entry. Server
accepts it, validates it as a UUID, and stores it in a new nullable
`played_games.game_id` column. No behavior depends on it yet — purely
additive accumulation, so both the api change and the client change are
independently revertible. **The server half is done** (api `2767b12`; see
Status above) — the remainder of this phase is client work.

This **is** an API contract change: both repos move, api deploys first
(additive — the server must accept the field before any client sends it).
The server tolerates the field's absence indefinitely; old clients never
upgrade in lockstep.

Server responses that describe a game (`/game/start`, `/game/progress`,
`/game/complete`, history rows) return the stored `game_id` — the first id
the row ever saw, keep-first — so the online-device gap closes and the
client convergence path ("adopt the server's winning id") exists before
Phase 2 needs it.

**Session-death completion replay (client, part of finishing Phase 1).**
When a session dies mid-game, `handleSessionInvalidated` snapshots the
board to local storage and the device finishes the game offline — and with
Phase 0.5, its anonymous writes no longer land on the claimed row, so the
completion would never reach the account. The replay closes that: on the
next login, if the server's copy of a game the client holds a completion
for is still in progress **and carries the same `game_id`**, the client
re-sends that completion, now authenticated. This is *not* a breach of
`online_play_redesign.md`'s no-merge rule: it never reconciles divergent
histories — it completes a game the server already knows, keyed by the id
the server itself returned, and the `(user_id, puzzle_num)` upsert (or
today's coalescing row upsert) makes it idempotent. It also finally gets
that game's completion into statistics, which the old anonymous
continuation never did.

### Phase 2 — create `games`, dual-write, backfill

1. Migration creates the `games` table as specified above.
2. Authenticated live writes and imports start **dual-writing**: the
   existing `played_games` upsert as today, plus an upsert into `games` on
   `ON CONFLICT (user_id, puzzle_num) DO UPDATE` (with the same
   coalesce-style protections the current upserts use — a lagging progress
   retry must not reset a recorded WIN). Requests without a `game_id` (old
   clients) mint one server-side at insert.
3. Backfill from `played_games where user_id is not null`, **after**
   dual-writing is live so there is no gap: one row per `(user_id,
   puzzle_num)`, winner chosen by the canonical rule as amended in Phase
   0.5 (completed rows first, then earliest `(created_at, id)`), inserted
   with `ON CONFLICT DO NOTHING` so live dual-written rows always win over
   backfill. Where the source row has a stored `game_id` (Phase 1 data),
   carry it as `client_game_id`; otherwise mint a **backdated UUIDv7 from
   the row's `completed_at`** (falling back to `created_at`) so historical
   ordering survives into the new ids.

Backfill touches rows, never numbers: it reproduces the canonical view of
history and **does not move anyone's statistics** — including for users
whose historical wins were lost to the pre-0.5 canonical rule. That follows
directly from the stats-immutability decision above: there is no repair
pass, not as part of this migration and not as a follow-up. A user who
spots an undercount has the manual adjustment tool, which is audited and
theirs to drive.

Phase 2 is api-only, invisible to clients, and revertible by dropping the
table and the dual-write.

### Phase 3 — cut reads over to `games` (the risky one)

Reads that move: `history_get_response` (currently
`PlayedGame.where(user_id:)` + `history_hash_for`'s collapse) reads `games`
directly — one row per puzzle guaranteed, no collapse. The canonical lookup
inside `apply_played_game_to_statistics!` reads the `games` row instead of
`canonical_played_game_for`. The stats blob itself stays in
`user_profiles.statistics`, event-applied exactly as today; the
anchor/contiguity rule is untouched.

**Verification happens in production, behind the writes, before any flip:**
dual-write both tables, keep reading old, and on every read compute both
answers, compare, and log divergence with enough context to diagnose
(user_id, puzzle_num, which side had what). Soak until the divergence log is
quiet for real traffic, then flip reads behind a per-deployment flag. Flip
staging's flag first, but do not mistake that for the verification — staging
cannot reproduce the data diversity that matters: multi-device users, legacy
imports, broken streak chains, and pre-history aggregate totals (the thing
`statsDiscrepancyAfterPush` exists to catch). The comments above app.rb's
stats section record that a prior full-recompute-from-history approach
caused real data loss; that history is why this phase gets the paranoid
treatment instead of a recompute-and-compare-once script.

Flag mechanism: the read flip is server-side, so the flag lives in the api's
per-deployment `config/app_config.yml` (Capistrano-shared, per-environment —
the server-side counterpart of the client's `LEFT_WORDLE_CONFIG` override
pattern established by `passkeyAuthEnabled`). Flipping back is a config
change and restart, not a deploy — that is the revert story for this phase.

No client change; no contract change (response shapes are identical, which
is exactly what the dual-read comparison proves).

### Phase 4 — contract: drop user_id, delete canonicalization

Only after Phase 3 has soaked and the flag has been on everywhere long
enough that reverting to old reads is off the table:

1. Stop dual-writing `user_id` to `played_games`; authenticated requests
   write `played_games` as pure telemetry (identical to the anonymous path)
   plus their `games` row.
2. Migration adds `authenticated` (backfilled as `user_id IS NOT NULL`),
   then drops `played_games.user_id` and the transitional
   `played_games.game_id` — per the telemetry-column decisions in "Target
   model" above, no join path to accounts survives.
3. Delete `canonical_played_game_for`, the `history_hash_for` collapse rule,
   the `:non_canonical` branch, `owned_row_scope`, and the import
   `RETURNING` gate.

This is the one phase that is **not** independently revertible: dropping
`user_id` destroys the row↔account mapping (that's the point — it's the
privacy win). Everything before it must be fully settled first. Client-side
removals, if any contract fields disappear, deploy client-first per the
sequencing rule below.

## Release sequencing rules

- **Expand / migrate / contract.** Additive contract changes deploy api
  first (Phases 1–2); removals deploy client first (Phase 4, if any field
  is removed from requests). The repos version independently and their tags
  are not in lockstep — never assume a client version implies an api
  version or vice versa.
- **Every phase is independently revertible except Phase 4**, and Phase 3's
  revert is a config flip, not a deploy.
- Standard deploy topology applies: staging soaks first per
  `branch_deploy_to_staging.md`, but for Phase 3 the production dual-read
  divergence log — not staging — is the acceptance gate.

## Cross-references

- `client/docs/online_play_redesign.md` — the two-mode (offline/online)
  design this composes with. Its "one live writer" reasoning is partly
  superseded: the anchor/contiguity rule still handles out-of-order
  catch-up play, but arrival-order races between devices are now settled
  by `UNIQUE (user_id, puzzle_num)` at write time rather than assumed away.
- `client/docs/migration_rethink.md` — the preserve-information principle
  (why every device's telemetry row is still kept) and the recompute
  data-loss history behind Phase 3's caution.
- `api/docs/database.md`, `api/docs/api_interface.md` — update alongside the
  phases that change schema and contract.
