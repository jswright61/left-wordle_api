# frozen_string_literal: true

require "json"
require "rack"
require "stringio"
require "tmpdir"

module VerboseLogging
  FLAG_FILE = File.join(Dir.tmpdir, "left_wordle_verbose_logging")

  def self.enabled?
    File.exist?(FLAG_FILE)
  end

  def self.enabled=(value)
    if value
      File.write(FLAG_FILE, "")
      $stdout.puts "= = = = = = = = = = = = = = = Verbose Logging on = = = = = = = = = = = = = = ="
    elsif File.exist?(FLAG_FILE)
      File.delete(FLAG_FILE)
      $stdout.puts "= = = = = = = = = = = = = = = Verbose Logging off = = = = = = = = = = = = = = ="
    end
  end

  def self.clear!
    File.delete(FLAG_FILE) if File.exist?(FLAG_FILE)
  end
end

class VerboseLogger
  # Matches Rack::CommonLogger's format exactly
  ACCESS_FORMAT = %{%s - %s [%s] "%s %s%s%s %s" %d %s %0.4f\n}

  # Absorbs any writes from an outer Rack::CommonLogger (added by rackup in development)
  # so its BodyProxy callback produces no output after we've already logged.
  NULL_IO = Class.new do
    def write(*) = 0
    def puts(*) = nil
    def <<(*) = self
    def flush = nil
    def close = nil
    def sync=(*)
    end
  end.new

  def initialize(app, output: $stdout)
    @app = app
    @output = output
    VerboseLogging.clear!
  end

  def call(env)
    began_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    verbose = VerboseLogging.enabled?

    if verbose
      body_input = env["rack.input"].read
      env["rack.input"] = StringIO.new(body_input)
      query_params = Rack::Request.new(env).GET.dup
    end

    status, headers, body = @app.call(env)

    chunks = []
    body.each { |chunk| chunks << chunk }
    body.close if body.respond_to?(:close)

    log_access(env, status, headers, began_at)
    log_verbose(body_input, query_params, chunks) if verbose

    env["rack.errors"] = NULL_IO
    [status, headers, chunks]
  end

  private

  def log_access(env, status, headers, began_at)
    request = Rack::Request.new(env)
    length = headers["content-length"] || headers["Content-Length"]
    length = (!length || length == "0") ? "-" : length
    query = request.query_string.empty? ? "" : "?#{request.query_string}"
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began_at

    msg = ACCESS_FORMAT % [
      request.ip || "-",
      request.get_header("REMOTE_USER") || "-",
      Time.now.strftime("%d/%b/%Y:%H:%M:%S %z"),
      request.request_method,
      request.script_name,
      request.path_info,
      query,
      request.get_header("SERVER_PROTOCOL"),
      status,
      length,
      elapsed
    ]

    @output.write(msg)
  end

  def log_verbose(body_input, query_params, chunks)
    req_body = body_input.empty? ? {} : begin
      JSON.parse(body_input)
    rescue JSON::ParserError
      body_input
    end

    resp_body = begin
      JSON.parse(chunks.join)
    rescue JSON::ParserError
      chunks.join
    end

    @output.puts "  request: body: #{req_body.inspect}, query_params: #{query_params.inspect}"
    @output.puts "  response: body: #{resp_body.inspect}"
  end
end
