# Database

Postgres via [Sequel](https://sequel.jeremyevans.net/), migrated with Sequel's
built-in migrator. Currently holds `guesser_users` (the `/guesser` tool's
Basic Auth login), `answers` (the puzzle sequence), and `legal_words`
(allowed guesses).

## Primary keys

Every table uses a `uuid` primary key defaulting to Postgres 18's native
`uuidv7()` (`primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)`
in migrations) — no extension needed, but it does require Postgres 18+.
UUIDv7 embeds a timestamp prefix so inserts stay roughly sequential in the
index (unlike v4), and IDs can be generated app-side before an insert. This
is the standard for new tables going forward too.

`answers.position` remains a separate plain integer column, not the primary
key — `answer_for` needs a gapless 0..N-1 sequence for `puzzle_number %
count`, which a UUID can't provide.

## Local setup

```bash
brew install postgresql@18
createdb left_wordle_api_development
createdb left_wordle_api_test
bundle exec rake db:migrate
bundle exec rake db:seed
```

No connection config is needed locally — `lib/db.rb` defaults to
`postgres:///left_wordle_api_#{RACK_ENV}` (local trust auth, no password)
when `config/app_config.yml` has no `database_url` and `DATABASE_URL` isn't
set. `rake test` runs `db:test:prepare` (migrate + seed) against the `_test`
database automatically.

## Migrations

Plain Sequel migration files in `db/migrate/`, named `NNN_description.rb`:

```bash
bundle exec rake db:migrate            # run all pending migrations
bundle exec rake db:migrate[2]         # migrate to a specific version
bundle exec rake db:rollback           # roll back one step
bundle exec rake db:rollback[0]        # roll back everything
```

See `db/migrate/001_create_users.rb` for the `Sequel.migration do change ... end`
pattern.

## Seed data

`db/seeds/answers.txt` (one word per line, in puzzle order) and
`db/seeds/legal_words.txt` are the checked-in source of truth for bootstrapping
a fresh database — `rake db:seed` loads them and is safe to rerun.

They're kept in sync automatically: `rake word_lists:add_answers` and
`rake word_lists:add_legal_words` write new words to the DB the task is
pointed at (via `DATABASE_URL`/`config/app_config.yml`) and then regenerate
both `db/seeds/*.txt` and `client/src/valid_guesses.js` from that DB, exactly
as the old file-generation rake tasks used to.

## Answer ordering

`answers.position` is an explicit 0-indexed column, not the row `id`.
`LeftWordle::Game.answer_for(puzzle_number)` does `puzzle_number % count`
against the array loaded from `Answer.order(:position)`, which requires a
gapless 0..N-1 sequence — don't rely on `id` order for this.

## Word lists stay in memory

`answers`/`legal_words` are loaded into frozen in-memory structures once at
boot (`LeftWordle::Game.load_words!`, called from `app.rb`'s `configure`
block) rather than queried per-request — `answer_for`/`valid_guess?` run on
every guess and need to stay zero-latency. Postgres is the source of truth
for admin purposes (the `word_lists` rake tasks); the running app doesn't
hit it after boot for word lookups.

## Deploying

`lib/capistrano/tasks/db.rake` runs `bundle exec rake db:migrate` on the
server after each deploy's code is in place, before the app restarts.
Staging and production each need their own `database_url` set in their
server-side `shared/config/app_config.yml` (gitignored, never in a
checked-in file) — provisioning Postgres itself on `paula-poundstone` and
setting those values is a separate, not-yet-done step.

When that step happens, create both databases with explicit locale/encoding
flags rather than relying on the server's cluster default — the local dev/test
databases are `C`/`UTF8` (confirmed via `psql -c "SELECT datname, datcollate,
datctype FROM pg_database"`), and staging/production must match exactly
regardless of what that server's `initdb` defaulted to, since staging and
production may not always live on the same box:

```bash
createdb --template=template0 --encoding=UTF8 --locale=C --lc-collate=C --lc-ctype=C left_wordle_api_production
createdb --template=template0 --encoding=UTF8 --locale=C --lc-collate=C --lc-ctype=C left_wordle_api_staging
```
