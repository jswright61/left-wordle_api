# Cache Rules Verification

Admin runbook for confirming that Cloudflare's cache rules and Caddy's `Cache-Control` headers agree after a rules change or a deploy.

**This is not `/things-to-test`.** That page is written for testers exercising the game in a browser. This is an operator task: it runs from a shell against a hostname, its pass condition is a set of response headers, and nothing it checks is visible to a player. Keep the two separate — cache verification does not belong in tester-facing pages.

Setup, rule shapes, and the token instructions live in `cloudflare_caching_setup.md` at the repo root. This document covers only verification.

---

## Quick reference

| | |
|---|---|
| Script | `bin/verify-cache-rules staging` / `bin/verify-cache-rules prod` |
| Rule count | 3 per hostname, 6 of the free plan's 10 |
| Zone ID | `8111259d817302b1c2a208e940e407b2` |
| Rules task | `CF_CACHE_RULES_TOKEN=... bundle exec rake 'create_cache_rules[staging]'` |
| Purge | automatic on `deploy:published` in both repos |

---

## The fast path

```bash
cd /Users/scott/repos/jswright61/left_wordle/api
./bin/verify-cache-rules staging
```

It checks every path class against the header the origin should be sending and against whether Cloudflare will actually cache it, then exits non-zero if anything failed. Run it after `create_cache_rules[staging]`, and again with `prod` after promoting.

A clean run ends with:

```text
----------------------------------------------------------
Result: 43 passed, 0 failed  (43 checks against https://staging.left-wordle.com)
```

When anything fails, the same counts are followed by a numbered reprint of every failed check and its detail, so you do not have to scroll back through the run to find them:

```text
Result: 40 passed, 3 failed  (43 checks against https://staging.left-wordle.com)

3 failed check(s):

  1. /things-to-test-tasks — edge cacheable
     want a cacheable CF-Cache-Status, got: DYNAMIC
     a DYNAMIC here means no cache rule covers this path

  2. /app_version.js — Cache-Control
     want: no-cache
     got:  max-age=14400
```

The script covers most of this document. The sections below explain what each check means, and cover the things a header probe cannot see.

---

## What each class should return

Cloudflare decides eligibility; Caddy decides every TTL. So each row has two independent assertions: the header came from Caddy unmodified, and Cloudflare agreed to cache it.

| Path | `Cache-Control` | `CF-Cache-Status` |
|------|-----------------|-------------------|
| `/`, `/privacy`, `/release-notes`, `/logins-and-passkeys`, `/things-to-test`, `/things-to-test-tasks`, `/retire-words`, `/seed-legacy`, `/online-accounts`, `/stats-checker` | `public, max-age=0, s-maxage=7200, must-revalidate` | `HIT` / `MISS` |
| `/app_version.js`, `/version.json` | `no-cache` | `REVALIDATED` / `MISS` |
| `/app_config.js`, `/src/*.js`, `/src/*.css` | `public, max-age=0, s-maxage=31536000, must-revalidate` | `HIT` / `MISS` |
| `*.png *.jpg *.jpeg *.gif *.svg *.ico *.webp *.xml *.txt` | `public, max-age=86400, s-maxage=2592000` | `HIT` / `MISS` |
| `GET /api/v1/game/answer?date=…` | `public, max-age=300, s-maxage=86400` | `HIT` / `MISS` |
| every other `/api/…`, `POST /api/v1/game/start`, `/guesser*` | `no-store` | `DYNAMIC` / `BYPASS`, never `HIT` |
| a 404 on an unknown path | `public, max-age=0, s-maxage=7200, must-revalidate` | `DYNAMIC` — see below |

**Why `REVALIDATED` is the healthy answer for release markers.** The rule makes them eligible for cache with `edge_ttl: respect_origin`, and the origin says `no-cache`. Cloudflare therefore stores the object but revalidates with the origin on every request. That is the intent: the edge absorbs the bandwidth, the client always gets the current version.

**Why a 404 shows `DYNAMIC`.** An arbitrary unknown path matches no cache rule, so Cloudflare declines to cache it and a typo'd URL never occupies the edge. Caddy still sets a header on it, which is the part worth asserting — `handle_errors` runs its own middleware chain and does not inherit the `handle` block above it, so the header is repeated there and could be dropped by an edit that looks unrelated.

---

## The two failure modes of an uncovered path

When no rule matches, Cloudflare falls back to default cache behavior keyed on the **file extension**. This produces two different symptoms, and only one of them looks like a problem:

**A default-cacheable extension (`.js`, `.css`, images) — the header is silently rewritten.** Cloudflare caches the response and applies the zone's Browser Cache TTL (4 hours), replacing what the origin sent. Signature: `cache-control: max-age=14400`.

**No extension, or `.json` — no edge caching at all.** `CF-Cache-Status: DYNAMIC`, headers intact, every request goes to the origin. Nothing looks wrong; you only find it by checking the status.

This is why both assertions are in the table. Checking `Cache-Control` alone would have missed `/things-to-test-tasks` sitting uncached for the life of the page, and checking `CF-Cache-Status` alone would have missed `/app_version.js` being rewritten.

**Fastest global check** — nothing on the site should ever return this:

```bash
for p in / /app_version.js /version.json /app_config.js /src/wordle.js /favicon.ico; do
  printf '%-20s ' "$p"
  curl -sI "https://staging.left-wordle.com$p" | grep -i '^cache-control:' | tr -d '\r'
done | grep 14400 && echo "FAIL: Browser Cache TTL is winning somewhere"
```

---

## Why the release markers matter more than they look

`/app_version.js` sets `window.APP_VERSION`, which feeds four things: the version link in the UI, the Sentry `release` tag, the diagnostics payload in `toolsmenu.js`, and `StatisticsEngine.getMigratedByVersion()`.

The last one is the reason this is worth a rule. `getMigratedByVersion` stamps `migratedBy` into the statistics it persists to local storage. A browser holding a stale `app_version.js` writes the *old* version into a record that outlives the cache entry — and stats are never repaired or backfilled after the fact, so a wrong stamp stays wrong. A four-hour caching window leaves a permanent mark.

**End-to-end check after a deploy:**

```bash
curl -sS https://staging.left-wordle.com/app_version.js
# => window.APP_VERSION = "v1.0.4";
```

Then load the site in a fresh private window and confirm the version shown in the UI matches the tag you deployed. If the file is right but the page shows an older version, you are looking at a browser cache that a `no-cache` header should have prevented — re-run the header check.

---

## Confirming the rules Cloudflare actually holds

The script tests behavior. This tests the rule set itself, which is what catches a rule that silently failed to write or one somebody disabled in the dashboard.

```bash
curl -sS -H "Authorization: Bearer $CF_CACHE_RULES_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/8111259d817302b1c2a208e940e407b2/rulesets/phases/http_request_cache_settings/entrypoint" \
  | python3 -c 'import json,sys
for r in json.load(sys.stdin)["result"].get("rules", []):
    print("%-52s enabled=%-5s %s" % (r.get("ref"), r.get("enabled"), r.get("description")))'
```

Expect exactly six managed rules, all `enabled=True`:

```text
left_wordle_staging_bypass_dynamic
left_wordle_staging_cache_answer_api
left_wordle_staging_cache_site_content
left_wordle_prod_bypass_dynamic
left_wordle_prod_cache_answer_api
left_wordle_prod_cache_site_content
```

**Things to look for:**

- **More than six**, or any ref not in that list — a retired rule was stranded. The task sweeps by `left_wordle_<env>_` ref prefix, so this should not happen; if it does, the extra rule predates that logic or was made by hand. Delete it in the dashboard.
- **`enabled=False`** — someone disabled a rule in the dashboard. Re-running the rake task writes all managed rules as enabled, which is the intended way to undo it.
- **Fewer than three for a hostname** — the task never ran for that environment, or ran against the wrong one.
- **Total approaching 10** — the free plan ceiling for the zone. Both hostnames share it.

---

## Edge behavior checks

**A second request should promote MISS to HIT:**

```bash
curl -sS -D - -o /dev/null https://staging.left-wordle.com/ | grep -i cf-cache-status
curl -sS -D - -o /dev/null https://staging.left-wordle.com/ | grep -i cf-cache-status
# MISS (or EXPIRED), then HIT
```

`REVALIDATED` on repeat for the release markers is correct and will never become `HIT`.

**The answer API must keep the query string in its cache key.** Two dates must be two objects — if the second date returns the first date's answer, the cache key is ignoring query strings and the daily answer is being served wrong:

```bash
for d in 2021-06-19 2021-06-20; do
  printf '%s -> ' "$d"
  curl -sS -H 'Sec-Fetch-Site: same-origin' \
    "https://staging.left-wordle.com/api/v1/game/answer?date=$d"
  echo
done
```

**A purge should reset everything to MISS.** The deploy hook in both repos purges the whole zone on `deploy:published` and aborts the deploy if it fails, so a successful deploy means a successful purge. To confirm, or to purge by hand, see "Manual Purge" in `cloudflare_caching_setup.md`. Immediately after one, every cacheable path returns `MISS` on its first request.

Because staging and production share a zone, `purge_everything` from a staging deploy also clears production's edge. Harmless, but it explains a burst of prod `MISS`es right after a staging deploy.

---

## Triage

| Symptom | Cause | Fix |
|---------|-------|-----|
| `cache-control: max-age=14400` | No rule matches; zone Browser Cache TTL overwrote the origin | Add the path to `CACHEABLE_PATHS`, re-run the rake task |
| `CF-Cache-Status: DYNAMIC` on a path that should cache | No rule matches, and the extension isn't default-cacheable | Same fix |
| Headers right, `DYNAMIC` everywhere including `/` | Rules missing entirely for that hostname | Run `create_cache_rules[<env>]` |
| `CF-Cache-Status: HIT` on an `/api/` route other than the answer | Bypass rule missing, disabled, or its expression edited | Re-run the rake task; check the answer-API exclusion survived |
| Stale page after a deploy | Purge did not run, or the browser is holding a `max-age` it should never have had | Check the deploy log for "Cloudflare cache purge requested"; then check the header |
| No `Cache-Control` at all | Path matches no Caddy matcher | Add it to the right matcher in `config/caddy/sites/*`, deploy, then add it to `CACHEABLE_PATHS` |
| Rules task reports success, dashboard unchanged | Ran against the other hostname | Check the environment argument |

---

## When you add a page or an asset type

Three places have to agree, and they have drifted apart before:

1. **Caddy** — add the path to the right matcher in *both* `config/caddy/sites/staging.left-wordle.com` and `config/caddy/sites/production.left-wordle.com`. Deploy the API repo, which syncs it via `caddy:sync_site`.
2. **Cloudflare** — add it to `CACHEABLE_PATHS` (or the extension lists) in `lib/tasks/cloudflare_cache_rules.rake`. Edit the constants, not the expression string. Run the task for both environments.
3. **Verify** — add it to `bin/verify-cache-rules` so the next person's run catches it.

Anything under `/src/` with a `.js` or `.css` extension needs no config change in either system. That is the point of keeping client code there, and the reason `/app_version.js` must stay *out* of it — a bare `*.js` matcher captures it and overrides its `no-cache`, confirmed against a local Caddy.

---

## Promoting to production

1. Run the rules task for staging, then `./bin/verify-cache-rules staging`. It must be clean.
2. Let staging soak. Production is a separate stack; nothing here promotes itself.
3. Run `create_cache_rules[prod]`.
4. Run `./bin/verify-cache-rules prod`.
5. Re-check the rule inventory — production had `cache_answer_api` disabled by hand once, and the task re-enables every managed rule it writes.

Deploy order when both the client and the rules change: the client ships the files first, the API repo's deploy syncs the Caddyfile, and the Cloudflare task runs last. A rule pointing at a path the origin does not serve yet caches a 404.
