# frozen_string_literal: true

require_relative "test_helper"

class VerboseLoggingModuleTest < Minitest::Test
  def setup
    VerboseLogging.clear!
  end

  def teardown
    VerboseLogging.clear!
  end

  def test_disabled_by_default
    refute VerboseLogging.enabled?
  end

  def test_enabled_when_flag_file_present
    File.write(VerboseLogging::FLAG_FILE, "")
    assert VerboseLogging.enabled?
  end

  def test_set_true_creates_flag_file
    capture_io { VerboseLogging.enabled = true }
    assert File.exist?(VerboseLogging::FLAG_FILE)
  end

  def test_set_true_prints_on_banner
    out, = capture_io { VerboseLogging.enabled = true }
    assert_match(/Verbose Logging on/, out)
  end

  def test_set_false_removes_flag_file
    capture_io { VerboseLogging.enabled = true }
    capture_io { VerboseLogging.enabled = false }
    refute File.exist?(VerboseLogging::FLAG_FILE)
  end

  def test_set_false_prints_off_banner
    capture_io { VerboseLogging.enabled = true }
    out, = capture_io { VerboseLogging.enabled = false }
    assert_match(/Verbose Logging off/, out)
  end

  def test_set_false_when_already_off_is_silent
    out, = capture_io { VerboseLogging.enabled = false }
    assert_empty out
  end

  def test_clear_removes_flag_file
    capture_io { VerboseLogging.enabled = true }
    VerboseLogging.clear!
    refute File.exist?(VerboseLogging::FLAG_FILE)
  end

  def test_clear_is_noop_when_already_off
    VerboseLogging.clear!
    refute File.exist?(VerboseLogging::FLAG_FILE)
  end
end

class VerboseLoggerMiddlewareTest < Minitest::Test
  JSON_APP = ->(env) { [200, {"content-type" => "application/json"}, ['{"ok":true}']] }

  def setup
    VerboseLogging.clear!
    @output = StringIO.new
    @middleware = VerboseLogger.new(JSON_APP, output: @output)
    @request = Rack::MockRequest.new(@middleware)
  end

  def teardown
    VerboseLogging.clear!
  end

  def test_initialize_clears_verbose_flag
    capture_io { VerboseLogging.enabled = true }
    VerboseLogger.new(JSON_APP, output: @output)
    refute VerboseLogging.enabled?
  end

  def test_always_writes_access_log
    @request.get("/")
    assert_includes @output.string, "GET"
  end

  def test_access_log_includes_status_code
    @request.get("/")
    assert_match(/\b200\b/, @output.string)
  end

  def test_access_log_includes_path
    @request.get("/some/path")
    assert_includes @output.string, "/some/path"
  end

  def test_response_body_passes_through_unchanged
    response = @request.get("/")
    assert_equal '{"ok":true}', response.body
  end

  def test_verbose_off_produces_only_access_line
    @request.get("/")
    assert_equal 1, @output.string.lines.length
  end

  def test_verbose_on_produces_three_lines
    capture_io { VerboseLogging.enabled = true }
    @request.get("/", input: "")
    assert_equal 3, @output.string.lines.length
  end

  def test_verbose_on_logs_json_request_body
    capture_io { VerboseLogging.enabled = true }
    @request.post("/", input: '{"guess":"crane"}', "CONTENT_TYPE" => "application/json")
    assert_match(/request:.*body:.*guess.*crane/, @output.string)
  end

  def test_verbose_on_logs_query_params
    capture_io { VerboseLogging.enabled = true }
    @request.get("/?date=2021-06-19", input: "")
    assert_match(/query_params:.*date.*2021-06-19/, @output.string)
  end

  def test_verbose_on_logs_response_body
    capture_io { VerboseLogging.enabled = true }
    @request.get("/", input: "")
    assert_match(/response:.*ok.*true/, @output.string)
  end

  def test_verbose_on_represents_empty_request_body_as_empty_hash
    capture_io { VerboseLogging.enabled = true }
    @request.get("/", input: "")
    assert_includes @output.string, "body: {}"
  end

  def test_verbose_on_handles_non_json_request_body
    plain_app = ->(env) { [200, {}, ["pong"]] }
    middleware = VerboseLogger.new(plain_app, output: @output)
    capture_io { VerboseLogging.enabled = true }
    Rack::MockRequest.new(middleware).post("/", input: "plain text", "CONTENT_TYPE" => "text/plain")
    assert_match(/body: "plain text"/, @output.string)
  end

  def test_verbose_on_handles_non_json_response_body
    plain_app = ->(env) { [200, {"content-type" => "text/plain"}, ["pong"]] }
    middleware = VerboseLogger.new(plain_app, output: @output)
    capture_io { VerboseLogging.enabled = true }
    Rack::MockRequest.new(middleware).get("/", input: "")
    assert_match(/response: body: "pong"/, @output.string)
  end
end

class VerboseLoggingApiTest < Minitest::Test
  include ApiTest

  def setup
    VerboseLogging.clear!
    origins = ENV["CORS_ORIGINS"].to_s.split(",").map(&:strip).reject(&:empty?)
    LeftWordleApi.set :allowed_origins, origins.freeze
    header "Authorization", "Bearer 1234"
  end

  def teardown
    VerboseLogging.clear!
  end

  def test_get_verbose_returns_false_when_off
    get "/api/v1/debug/verbose"

    assert last_response.ok?
    assert_equal false, json_response.fetch("verbose_logging")
  end

  def test_get_verbose_returns_true_when_on
    capture_io { VerboseLogging.enabled = true }
    get "/api/v1/debug/verbose"

    assert last_response.ok?
    assert_equal true, json_response.fetch("verbose_logging")
  end

  def test_post_verbose_enables_verbose_logging
    post_json "/api/v1/debug/verbose", {enabled: true}

    assert last_response.ok?
    assert_equal true, json_response.fetch("verbose_logging")
    assert VerboseLogging.enabled?
  end

  def test_post_verbose_disables_verbose_logging
    capture_io { VerboseLogging.enabled = true }
    post_json "/api/v1/debug/verbose", {enabled: false}

    assert last_response.ok?
    assert_equal false, json_response.fetch("verbose_logging")
    refute VerboseLogging.enabled?
  end

  def test_post_verbose_rejects_string_value_for_enabled
    post_json "/api/v1/debug/verbose", {enabled: "yes"}

    assert_equal 400, last_response.status
    assert_match(/true or false/, json_response.fetch("detail"))
  end

  def test_post_verbose_rejects_integer_value_for_enabled
    post_json "/api/v1/debug/verbose", {enabled: 1}

    assert_equal 400, last_response.status
    assert_match(/true or false/, json_response.fetch("detail"))
  end

  def test_post_verbose_rejects_missing_enabled_key
    post_json "/api/v1/debug/verbose", {}

    assert_equal 400, last_response.status
    assert_match(/true or false/, json_response.fetch("detail"))
  end

  # An allowed Origin satisfies the app-wide origin check but must NOT be
  # enough for the operator-only debug toggle -- that requires the server
  # API token itself.
  def test_post_verbose_requires_the_server_api_token
    header "Authorization", nil
    origin = ENV["CORS_ORIGINS"].to_s.split(",").first.strip

    post_json "/api/v1/debug/verbose", {enabled: true}, {"HTTP_ORIGIN" => origin}

    assert_equal 401, last_response.status
    refute VerboseLogging.enabled?
  end

  def test_get_verbose_requires_the_server_api_token
    header "Authorization", nil
    origin = ENV["CORS_ORIGINS"].to_s.split(",").first.strip

    get "/api/v1/debug/verbose", {}, {"HTTP_ORIGIN" => origin}

    assert_equal 401, last_response.status
  end
end
