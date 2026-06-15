# Left Wordle API

A small Sinatra API that owns Left Wordle's answer list and guess evaluation.
The browser remains responsible for in-progress state, history, statistics, and
display behavior.

## Setup

```zsh
rv run bundle install
rv run bundle exec rackup
```

The API listens on `http://localhost:9292` by default.

## Endpoints

### `GET /api/v1/health`

Returns a basic availability response.

### `GET /api/v1/game/puzzle`

Returns the puzzle number and word length for the requested date:

```text
GET /api/v1/game/puzzle?date=2021-06-19
```

### `POST /api/v1/game/guess`

Evaluates a guess for the requested puzzle date. The request body is:

```json
{
  "date": "2021-06-19",
  "guess": "crane",
  "row_index": 0
}
```

`row_index` is zero-based. The solution is returned only when the guess wins or
the sixth guess fails.

Dates must use `YYYY-MM-DD`. Past dates are allowed. The latest accepted date is
the current date at UTC+14, which is the furthest-ahead civil time zone. This
allows the new puzzle as soon as that calendar date begins anywhere in the
world, while rejecting dates that are still in the future everywhere.

The original `/api/health`, `/api/game/today`, and `/api/game/guess` routes
remain available during the frontend transition. They return `Deprecation` and
`Link` headers identifying the corresponding versioned endpoint and will be
removed after all known clients have migrated.

## Configuration

`CORS_ORIGINS` is a comma-separated list of exact browser origins allowed to
call the API:

```zsh
CORS_ORIGINS=https://left-wordle.example.com,https://alternate.example.com
```

No browser origins are allowed by default. Requests from an origin outside the
list receive `403 Forbidden`. Include the public site's own origin because
browsers may send it on same-origin requests. Requests without an `Origin`
header remain available for server-to-server clients; CORS is not an
authentication mechanism for those clients.

## Checks

```zsh
rv run bundle exec rake test
rv run bundle exec standardrb
```

## Scope

This first version deliberately excludes accounts, passkeys, email, profiles,
server-side game state, history synchronization, background jobs, and a
database. Those features can be added behind separate API boundaries when the
frontend has a concrete need for them.
