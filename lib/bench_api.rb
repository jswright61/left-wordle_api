#!/Users/scott/.local/ruby/ruby-4.0-script
# frozen_string_literal: true

require "date"
require "open3"
require "json"
require "optparse"
require "csv"

# ── Configuration (overridable via CLI args) ───────────────────────────────────
API_BASE   = "https://api-staging.left-wordle.com"
ORIGIN     = "https://staging.left-wordle.com"
ENDPOINT   = "/api/v1/game/guess"
BODY       = JSON.generate(guess: "crane", mode: "regular", row_index: 0, prev_guesses: [], date: Date.today.iso8601)
# ──────────────────────────────────────────────────────────────────────────────

defaults = { iterations: 5, think_time: 2, csv_file: nil, include_options: false }

OptionParser.new do |o|
  o.on("--iterations N",  Integer, "Number of iterations   (default: #{defaults[:iterations]})") { |n| defaults[:iterations] = n }
  o.on("--think-time N",  Integer, "Seconds between guesses (default: #{defaults[:think_time]})") { |n| defaults[:think_time] = n }
  o.on("--csv-file FILE",          "Write results to CSV file") { |f| defaults[:csv_file] = f }
  o.on("--include-options-request", "Also time the OPTIONS preflight (default: POST only)") { defaults[:include_options] = true }
end.parse!

iterations      = defaults[:iterations]
think_time      = defaults[:think_time]
csv_path        = defaults[:csv_file]
include_options = defaults[:include_options]

URL = "#{API_BASE}#{ENDPOINT}"

CURL_FORMAT = [
  "status:%{http_code}",
  "dns:%{time_namelookup}",
  "connect:%{time_connect}",
  "appconnect:%{time_appconnect}",
  "ttfb:%{time_starttransfer}",
  "total:%{time_total}"
].join("\n").freeze

def curl_timing(extra_args)
  cmd = ["curl", "-s", "-o", "/dev/null", "-w", CURL_FORMAT] + extra_args
  out, = Open3.capture2(*cmd)

  raw = out.lines.each_with_object({}) do |line, h|
    k, v = line.strip.split(":", 2)
    h[k] = v if k && v
  end

  dns     = raw["dns"].to_f * 1000
  connect = raw["connect"].to_f * 1000
  appconn = raw["appconnect"].to_f * 1000

  {
    status:   raw["status"].to_i,
    dns_ms:   dns,
    tcp_ms:   connect - dns,
    tls_ms:   appconn > 0 ? appconn - connect : 0.0,
    ttfb_ms:  raw["ttfb"].to_f * 1000,
    total_ms: raw["total"].to_f * 1000
  }
end

def measure_options(url)
  curl_timing([
    "-X", "OPTIONS",
    "-H", "Origin: #{ORIGIN}",
    "-H", "Access-Control-Request-Method: POST",
    "-H", "Access-Control-Request-Headers: content-type",
    url
  ])
end

def measure_post(url, body)
  curl_timing([
    "-X", "POST",
    "-H", "Origin: #{ORIGIN}",
    "-H", "Content-Type: application/json",
    "-d", body,
    url
  ])
end

def row(label, r, status: true)
  status_col = status ? format("%3d", r[:status]) : "   "
  format(
    "  %-10s  %s  dns:%6.1f  tcp:%6.1f  tls:%6.1f  ttfb:%7.1f  total:%7.1f  (ms)",
    label, status_col,
    r[:dns_ms], r[:tcp_ms], r[:tls_ms], r[:ttfb_ms], r[:total_ms]
  )
end

def averages(results)
  keys = %i[dns_ms tcp_ms tls_ms ttfb_ms total_ms]
  keys.each_with_object({}) { |k, h| h[k] = results.sum { _1[k] } / results.size }
end

def per_guess_avg(opt_results, post_results, include_options)
  if include_options
    opt_results.zip(post_results).sum { |o, p| o[:total_ms] + p[:total_ms] } / opt_results.size
  else
    post_results.sum { _1[:total_ms] } / post_results.size
  end
end

def print_running_avgs(label, opt_results, post_results, include_options)
  post_avg = averages(post_results)
  combined = per_guess_avg(opt_results, post_results, include_options)
  if include_options
    opt_avg = averages(opt_results)
    puts format("  [%-8s]  per-guess:%7.1fms  OPTIONS:%7.1fms  POST:%7.1fms",
      label, combined, opt_avg[:total_ms], post_avg[:total_ms])
  else
    puts format("  [%-8s]  per-guess:%7.1fms  POST:%7.1fms",
      label, combined, post_avg[:total_ms])
  end
end

CSV_HEADERS = %w[iteration verb status dns_ms tcp_ms tls_ms ttfb_ms total_ms].freeze

def csv_row(iter, verb, r)
  [iter, verb, r[:status],
   r[:dns_ms].round(2), r[:tcp_ms].round(2), r[:tls_ms].round(2),
   r[:ttfb_ms].round(2), r[:total_ms].round(2)]
end

csv_io = csv_path ? CSV.open(csv_path, "w", headers: CSV_HEADERS, write_headers: true) : nil

options_results = []
post_results    = []

puts "URL:        #{URL}"
puts "Origin:     #{ORIGIN}"
puts "Iterations: #{iterations}  Think time: #{think_time}s#{csv_path ? "  CSV: #{csv_path}" : ""}"
puts "-" * 80

iterations.times do |i|
  n = i + 1
  puts "\nIteration #{n}:"

  if include_options
    opt = measure_options(URL)
    options_results << opt
    puts row("OPTIONS", opt)
    if csv_io
      csv_io << csv_row(n, "OPTIONS", opt)
      csv_io.flush
    end
  end

  pst = measure_post(URL, BODY)
  post_results << pst
  puts row("POST", pst)
  if csv_io
    csv_io << csv_row(n, "POST", pst)
    csv_io.flush
  end

  if n % 10 == 0
    puts "  #{"─" * 76}"
    print_running_avgs("last 10", options_results.last(10), post_results.last(10), include_options)
    print_running_avgs("overall", options_results, post_results, include_options)
    puts "  #{"─" * 76}"
  end

  if i < iterations - 1 && think_time > 0
    print "  sleeping #{think_time}s ."
    think_time.times { sleep 1; print "." }
    puts
  end
end

csv_io&.close

puts "\n#{"=" * 80}"
puts "Final averages over #{iterations} iterations:"
if include_options
  puts row("OPTIONS", averages(options_results), status: false)
end
puts row("POST", averages(post_results), status: false)
if include_options
  puts format("\n  Per-guess round-trip avg (OPTIONS + POST): %.1fms", per_guess_avg(options_results, post_results, true))
else
  puts format("\n  Per-guess round-trip avg (POST only): %.1fms", per_guess_avg([], post_results, false))
end
