# Frontend to API Transition Plan

This document describes how to move the currently deployed, browser-only Left
Wordle application in `python_wordle` to the Sinatra application in
`left_wordle_api` without losing the ability to ship production fixes during
the transition.

The goal is a staged replacement rather than a merge of the existing
`ruby-backend` branch.

## Repository Roles

Each repository or branch should have one clear role:

- `python_wordle`: the frontend and current production application.
- `left_wordle_api`: the new authoritative backend.
- `python_wordle/ruby-backend`: a read-only reference implementation.

Do not merge `ruby-backend` wholesale into the frontend's production branch.
At the time this plan was written, it was 14 commits ahead of `main` and
contained approximately 35,000 added lines. Those changes include two backend
implementations, frontend integration work, authentication, synchronization,
deployment machinery, and work-in-progress code. A wholesale merge would make
it difficult to distinguish reusable behavior from abandoned architecture.

Instead, port individual behaviors with focused tests into the repository that
will own them permanently.

## Preserve the Reference Work

Before reorganizing `python_wordle`, preserve all existing branches outside the
local clone. At the time of inspection, the repository had no Git remote
configured.

Create an immutable tag for the reference branch:

```zsh
git tag -a archive/ruby-backend-2026-06-15 ruby-backend
```

Push the tag and all branches after configuring a remote. An optional worktree
can keep the reference implementation available beside the active frontend:

```zsh
git worktree add ../python_wordle-ruby-reference ruby-backend
```

The worktree makes it easy to inspect code and tests without repeatedly
switching branches or introducing reference code into production changes.

The archive tag should remain unchanged. If additional reference work is ever
needed, make it on a new branch rather than moving the archive tag.

## Frontend Branch Strategy

Use `main` as the exact production line. Production fixes and migration work
should begin from the same current production commit.

Prefer short-lived branches such as:

```text
main
  |-- hotfix/...
  |-- feature/storage-controller
  |-- feature/api-client
  |-- feature/api-gameplay
  |-- feature/passkey-ui
  `-- feature/server-sync
```

Avoid a long-running migration branch. Long-running branches accumulate
conflicts and force production fixes to be copied or merged repeatedly. Small
features can instead be merged into `main` while remaining disabled through
configuration until they are ready.

At the time of inspection, `develop` differed from `main` only by one data-file
commit. Reconcile that change and retire `develop` unless it has a continuing,
explicit purpose. Maintaining both `main` and `develop` without a meaningful
release distinction increases uncertainty about what is deployed.

## Feature Configuration

Migration features should be independently controllable. Suggested flags are:

```text
API_GAMEPLAY_ENABLED
API_GAMEPLAY_SHADOW_MODE
PASSKEY_AUTH_ENABLED
SERVER_SYNC_ENABLED
LOCAL_GAMEPLAY_FALLBACK_ENABLED
```

The production frontend should obtain flags from a small configuration file or
endpoint that can be changed without rebuilding the application. Flags should
default to the existing production behavior when configuration is missing or
invalid.

Each feature must fail closed for private data and fail safely for gameplay.
For example, a sync failure must not delete local history, while a gameplay API
failure may temporarily use an explicitly enabled local fallback.

## Transition Stages

### 1. Stabilize Local Storage

Port the `StorageController` concept from `ruby-backend` independently of API
integration. It centralizes local storage access and provides a natural place
for schema migrations, validation, and compatibility behavior.

This stage should preserve all existing storage keys and values unless a
specific migration is tested. It can be deployed while gameplay remains fully
local.

Tests should cover:

- Existing users loading legacy storage.
- Empty or malformed values.
- Preferences migration.
- Current game persistence.
- History in every format previously deployed.
- Statistics and legacy-stat preservation.

### 2. Introduce a Frontend API Client

Create one frontend module responsible for all API communication. UI and game
modules should not call `fetch` directly.

The API client should own:

- API base URL configuration.
- Request and response JSON handling.
- Request timeouts and cancellation.
- CORS credential behavior.
- Consistent error objects.
- API version negotiation.
- Session and CSRF headers when authentication is added.
- Logging hooks that do not expose credentials or private data.

Start with health and puzzle metadata requests. This establishes deployment,
CORS, and error-handling behavior without changing gameplay.

### 3. Shadow Game Evaluation

In shadow mode, continue using the existing local evaluation as the result
shown to the player while also sending the guess to the Sinatra API.

Compare:

- Puzzle number and date.
- Evaluation for each letter.
- Win or failure status.
- Revealed solution after completion.
- Error classification for invalid guesses.

Record mismatches without blocking play. Do not log the current answer in a
public analytics system. Shadow requests should have conservative timeouts and
must not delay the existing interaction.

This stage proves that the frontend and API agree on puzzle dates, answer-list
ordering, duplicate-letter evaluation, and response contracts.

### 4. Make Gameplay API-Authoritative

After shadow results are consistently correct, enable API responses as the
authoritative source for guess evaluation.

Initially retain the local answer list and evaluator as an emergency fallback
behind `LOCAL_GAMEPLAY_FALLBACK_ENABLED`. This allows a production outage to be
mitigated quickly while the new deployment matures.

The fallback should be temporary. Keeping answers in the frontend permanently
defeats an important reason for introducing the API. Remove the client answer
list and local authoritative evaluator after the API-backed path has operated
reliably and rollback procedures have been tested.

### 5. Add Passkey Authentication

Port the behavior and tests from `ruby-backend`, not its Rails implementation
wholesale. The Sinatra API should own passkey challenges, credential storage,
verification, users, and sessions. The frontend should own only the browser
WebAuthn calls and user interface.

Useful reference material includes:

- Registration and authentication ceremony sequencing.
- Request and response shapes.
- Multiple-passkey user experience.
- Credential revocation concepts.
- Email recovery decisions, if that feature remains desired.
- Existing request tests and failure cases.

Reconsider the reference implementation's browser-stored JWT approach. Prefer
opaque server-side sessions using secure, `HttpOnly` cookies, with explicit
CSRF protection and exact WebAuthn origin validation. See
[`security_architecture.md`](security_architecture.md) for the intended security
model.

Authentication should be deployable before server synchronization is enabled.
That allows registration, login, logout, session expiry, and account recovery
to be exercised without risking game data.

### 6. Add State and History Synchronization

Treat browser storage as an offline-capable cache during the transition. Do not
delete local data merely because it was sent to the server.

Use explicit, idempotent endpoints for:

- Current game state.
- Completed game history.
- Preferences that genuinely need account synchronization.
- Legacy statistics or adjustment data.

Recommended initial rules are:

- History import is add-only.
- Existing server history is not silently overwritten.
- Current-game updates must represent valid progression.
- Every operation is scoped to the authenticated user derived from the session.
- Repeating an import produces the same result without duplicate records.
- Local data remains intact until the server confirms successful persistence.
- A failed pull never replaces valid local data with an empty response.
- Conflict behavior is deterministic, documented, and tested.

The sync algorithm from `ruby-backend` is reference material, not an automatic
contract. Review each rule against the desired product behavior before porting
it.

### 7. Remove Legacy Paths

Remove compatibility paths only after the replacement has run successfully in
production and rollback has been exercised.

Candidates include:

- The frontend answer list.
- Local authoritative guess evaluation.
- Deprecated local storage keys and migration code.
- Browser-stored authentication tokens.
- Old synchronization modules.
- Disabled feature flags.
- Abandoned FastAPI and Rails deployment code.

Removal should be a separate, reviewable change rather than part of the feature
that introduces the replacement.

## Production Hotfixes During Migration

Production bugs continue to be fixed from `main`:

1. Create `hotfix/<description>` from the deployed `main` commit.
2. Implement and test the narrow fix.
3. Merge it into `main` and deploy it normally.
4. Rebase or merge `main` into any short-lived feature branches that overlap
   the changed code.

Because incomplete migration work is merged only when independently safe and
is controlled by flags, there should be no separate migration branch requiring
manual hotfix propagation.

Tag production releases or record deployment commit SHAs. This makes rollback
and bug diagnosis possible even if `main` advances after deployment.

## Reuse Inventory

### Good Candidates to Port

- `StorageController` organization and storage migrations.
- Passkey registration and authentication flow knowledge.
- Authentication, game, profile, and service tests.
- Database entities and uniqueness constraints.
- Game-state and history JSON shapes.
- Login, passkey management, and synchronization UI concepts.
- Wordle evaluation and hard-mode test cases.
- Existing local-data import fixtures.

### Reimplement or Reconsider

- Rails controllers, models, jobs, and configuration.
- The duplicate FastAPI implementation.
- JWTs stored in browser local storage.
- Solid Queue and Rails-specific cleanup machinery.
- Push-then-pull synchronization without a reviewed conflict policy.
- Hosting the frontend from the backend application.
- Committed local TLS certificates.
- Environment and secret handling from the reference branch.
- Any work-in-progress code without tests or a clear product requirement.

When porting, copy the smallest coherent behavior and its tests. Adapt naming
and structure to the destination repository rather than preserving framework
boundaries that no longer apply.

## API Contract Ownership

`left_wordle_api` owns the API contract. Document endpoints and behavior in
this repository and enforce them with request tests.

Version the contract before it gains several consumers. A possible structure
is:

```text
/api/v1/game/puzzle
/api/v1/game/guess
/api/v1/auth/...
/api/v1/state/...
/api/v1/history/...
```

The current unversioned endpoints can remain temporarily as aliases during the
frontend transition. Set a removal milestone rather than maintaining both
indefinitely.

Contract documentation should define:

- Request and response fields.
- Authentication requirements.
- Date and time interpretation.
- Error status codes and JSON shapes.
- Idempotency behavior.
- Pagination and limits.
- Conflict and merge rules.
- CORS and credential expectations.
- Deprecation policy.

The frontend should have contract tests using representative API responses.
The API should have request tests that prove those same examples. Shared JSON
fixtures may be copied deliberately, but avoid coupling the repositories
through filesystem paths or Git submodules.

## Database and Migration Safety

Introduce the database before enabling authenticated state storage. Database
migrations should be owned and executed by `left_wordle_api`.

Before importing real user data:

- Define uniqueness constraints for user credentials, puzzle history, and
  current state.
- Test repeated imports and interrupted imports.
- Test rollback or forward-repair procedures for schema changes.
- Back up production data and test restoration.
- Record import counts and failures without logging private payloads.
- Provide users a way to retry synchronization safely.

Do not make local data removal part of the first successful import. Retention
allows recovery from server bugs discovered after rollout.

## Rollout and Observability

Roll out each major stage independently:

1. Local development and automated tests.
2. A non-production API and frontend configuration.
3. Shadow traffic with no user-visible behavior change.
4. A small opt-in or controlled group when practical.
5. General availability with a tested rollback flag.
6. Legacy-code removal after an observation period.

Monitor at least:

- Request counts and latency by endpoint.
- HTTP error rates.
- API timeout and network failures in the frontend.
- Shadow-evaluation mismatches.
- Passkey registration and login failures.
- Session and CSRF failures.
- Sync import counts, conflicts, and retries.
- Database errors and resource usage.

Logs and analytics must not include answers before puzzle completion, passkey
assertions, challenges, cookies, bearer tokens, or private game-history
payloads.

## Completion Criteria

The transition is complete when:

- Production gameplay obtains puzzle data and evaluations from the Sinatra API.
- The frontend no longer ships the answer list.
- Passkey login uses the final RP ID and secure server-side sessions.
- Authenticated users can safely synchronize current state and history.
- Local storage remains functional for offline use and recovery.
- Conflict behavior is documented and covered by tests.
- Public and Tailscale service paths follow the security architecture.
- Production rollback and database restoration have been tested.
- Rails and FastAPI reference implementations are archived rather than active.
- Obsolete feature flags and migration-only compatibility code are removed.
