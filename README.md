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

### `GET /api/health`

Returns a basic availability response.

### `GET /api/game/today`

Returns the puzzle number and word length for the requested date:

```text
GET /api/game/today?date=2021-06-19
```

### `POST /api/game/guess`

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

## Configuration

`CORS_ORIGIN` controls the value of `Access-Control-Allow-Origin`. It defaults
to `*` because the initial API is public and stateless.

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
