# frozen_string_literal: true

namespace :games do
  # Phase 2 of docs/played_games_ownership_rework.md.
  #
  # Copies every user-owned played_games row into games, one row per
  # (user_id, puzzle_num). Run this only AFTER the dual-write is deployed, so
  # there is no window where live play lands in played_games alone.
  #
  # Two invariants make it safe to run, re-run, and run alongside live play:
  #
  # - ON CONFLICT DO NOTHING. A live dual-written row always wins over the
  #   backfill; the backfill only ever fills gaps. Re-running is a no-op.
  # - It touches rows, never numbers. No statistics are recomputed or
  #   adjusted, including for users whose historical wins were lost to the
  #   pre-Phase-0.5 canonical rule -- see the stats-immutability decision in
  #   the design doc. Their remedy is the manual adjustment tool.
  #
  # The winner per (user_id, puzzle_num) is the canonical row as Phase 0.5
  # defines it: completed rows before in-progress ones, then earliest
  # arrival. That reproduces exactly the history and stats users already see,
  # rather than picking a different winner and silently changing their past.
  desc "Backfill games from user-owned played_games rows (idempotent)"
  task :backfill, [:batch_size] do |_t, args|
    require_relative "../db"

    batch_size = (args[:batch_size] || 1000).to_i
    inserted = 0
    scanned = 0

    # client_game_id is NOT NULL. Phase 1 rows carry a real client-minted id;
    # older rows get one minted here from the row's own timestamp, so the
    # UUIDv7 ordering still reflects when the game was actually played
    # instead of when this task happened to run. uuidv7(shift) offsets from
    # now(), so the shift is (target - now()). completed_at is the truest
    # play time available; created_at is the fallback for rows that never
    # completed.
    minted_id = Sequel.lit(
      "uuidv7(coalesce(played_games.completed_at, played_games.created_at) - now())"
    )

    # DISTINCT ON collapses each (user_id, puzzle_num) to its canonical row.
    # The ORDER BY must lead with the DISTINCT ON columns, then express the
    # canonical rule: game_status IS NULL sorts last (completed wins), then
    # earliest (created_at, id).
    canonical = DB[:played_games]
      .distinct(:user_id, :puzzle_num)
      .exclude(user_id: nil)
      .order(
        Sequel[:played_games][:user_id],
        Sequel[:played_games][:puzzle_num],
        Sequel.asc(Sequel.lit("played_games.game_status IS NULL")),
        Sequel[:played_games][:created_at],
        Sequel[:played_games][:id]
      )
      .select(
        Sequel[:played_games][:user_id],
        Sequel[:played_games][:puzzle_num],
        Sequel[:played_games][:date],
        Sequel[:played_games][:mode],
        Sequel[:played_games][:game_status],
        Sequel[:played_games][:guesses],
        Sequel[:played_games][:completed_at],
        Sequel[:played_games][:created_at],
        Sequel.as(Sequel.function(:coalesce, Sequel[:played_games][:game_id], minted_id), :client_game_id)
      )

    DB.transaction do
      canonical.paged_each(rows_per_fetch: batch_size) do |row|
        scanned += 1
        written = DB[:games].insert_conflict(target: [:user_id, :puzzle_num]).insert(
          client_game_id: row[:client_game_id],
          user_id: row[:user_id],
          puzzle_num: row[:puzzle_num],
          date: row[:date],
          mode: row[:mode],
          game_status: row[:game_status],
          guesses: row[:guesses],
          completed_at: row[:completed_at],
          # Preserve the original arrival time rather than stamping now(), so
          # the audit trail still says when this game actually reached us.
          created_at: row[:created_at],
          updated_at: Sequel::CURRENT_TIMESTAMP
        )
        inserted += 1 if written
      end
    end

    puts "Backfill complete: #{scanned} canonical played_games row(s) scanned, #{inserted} inserted, #{scanned - inserted} already present."
  end

  # Read-only companion to the backfill: reports where games and the
  # canonical view of played_games disagree. This is the Phase 3 go/no-go
  # signal in miniature -- run it after the backfill and again before
  # flipping reads.
  desc "Report rows where games disagrees with the canonical played_games view"
  task :verify do
    require_relative "../db"

    missing = DB.fetch(<<~SQL).all
      SELECT canonical.user_id, canonical.puzzle_num
      FROM (
        SELECT DISTINCT ON (user_id, puzzle_num) user_id, puzzle_num, game_status
        FROM played_games
        WHERE user_id IS NOT NULL
        ORDER BY user_id, puzzle_num, game_status IS NULL, created_at, id
      ) canonical
      LEFT JOIN games g
        ON g.user_id = canonical.user_id AND g.puzzle_num = canonical.puzzle_num
      WHERE g.id IS NULL
      LIMIT 50
    SQL

    mismatched = DB.fetch(<<~SQL).all
      SELECT canonical.user_id, canonical.puzzle_num,
             canonical.game_status AS played_games_status,
             g.game_status AS games_status
      FROM (
        SELECT DISTINCT ON (user_id, puzzle_num) user_id, puzzle_num, game_status
        FROM played_games
        WHERE user_id IS NOT NULL
        ORDER BY user_id, puzzle_num, game_status IS NULL, created_at, id
      ) canonical
      JOIN games g
        ON g.user_id = canonical.user_id AND g.puzzle_num = canonical.puzzle_num
      WHERE g.game_status IS DISTINCT FROM canonical.game_status
      LIMIT 50
    SQL

    orphaned = DB[:games].exclude(
      Sequel.lit("EXISTS (SELECT 1 FROM played_games pg WHERE pg.user_id = games.user_id AND pg.puzzle_num = games.puzzle_num)")
    ).count

    puts "games rows:               #{DB[:games].count}"
    puts "canonical played_games:   #{DB.fetch("SELECT count(*) AS c FROM (SELECT DISTINCT ON (user_id, puzzle_num) 1 FROM played_games WHERE user_id IS NOT NULL ORDER BY user_id, puzzle_num, game_status IS NULL, created_at, id) s").first[:c]}"
    puts "missing from games:       #{missing.length}#{" (showing first 50)" if missing.length == 50}"
    puts "status mismatches:        #{mismatched.length}#{" (showing first 50)" if mismatched.length == 50}"
    # Not a defect on its own: a game played after the backfill exists in
    # games and, once played_games drops user_id in Phase 4, will have no
    # counterpart at all. Reported so the number is explainable rather than
    # surprising.
    puts "games with no played_games counterpart: #{orphaned}"

    missing.each { |r| puts "  MISSING  user=#{r[:user_id]} puzzle=#{r[:puzzle_num]}" }
    mismatched.each do |r|
      puts "  MISMATCH user=#{r[:user_id]} puzzle=#{r[:puzzle_num]} played_games=#{r[:played_games_status].inspect} games=#{r[:games_status].inspect}"
    end
  end

  # Phase 3's go/no-go signal. The soak asks one question -- "have the two
  # reads stopped disagreeing for real traffic" -- and this answers it.
  # Empty output is the result you are waiting for.
  desc "Report dual-read divergences between played_games and games"
  task :divergences, [:limit] do |_t, args|
    require_relative "../db"

    limit = (args[:limit] || 50).to_i
    total = DB[:games_read_divergences].count

    if total.zero?
      puts "No read divergences recorded. (This is the result Phase 3 is waiting for.)"
      next
    end

    puts "#{total} divergent (read, user, puzzle) combination(s) recorded."
    puts
    DB[:games_read_divergences]
      .group_and_count(:read_name, :detail)
      .order(Sequel.desc(:count))
      .each { |r| puts format("  %-16s %-28s %d", r[:read_name], r[:detail].to_s[0, 28], r[:count]) }

    puts
    puts "Most recent #{[limit, total].min}:"
    DB[:games_read_divergences]
      .order(Sequel.desc(:last_seen_at))
      .limit(limit)
      .each do |r|
        puts format("  %-16s user=%s puzzle=%-6s seen=%dx  %s",
          r[:read_name], r[:user_id], r[:puzzle_num], r[:seen_count], r[:detail])
        puts "      played_games: #{r[:played_games_value]}"
        puts "      games:        #{r[:games_value]}"
      end
  end

  # Divergences are evidence, not history worth keeping forever. Once a
  # cause is understood and fixed, clearing lets the next soak window start
  # from a clean signal rather than from a backlog that has to be explained
  # every time.
  desc "Delete recorded read divergences (optionally only those older than [days])"
  task :clear_divergences, [:days] do |_t, args|
    require_relative "../db"

    scope = DB[:games_read_divergences]
    if args[:days]
      days = args[:days].to_i
      scope = scope.where(Sequel.lit("last_seen_at < now() - (? * interval '1 day')", days))
      puts "Deleted #{scope.delete} divergence row(s) last seen more than #{days} day(s) ago."
    else
      puts "Deleted #{scope.delete} divergence row(s)."
    end
  end
end
