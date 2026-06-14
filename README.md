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

Returns the current puzzle number, local server date, and word length.

### `POST /api/game/guess`

Evaluates a guess for today's puzzle. The request body is:

```json
{
  "guess": "crane",
  "row_index": 0
}
```

`row_index` is zero-based. The solution is returned only when the guess wins or
the sixth guess fails.

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
