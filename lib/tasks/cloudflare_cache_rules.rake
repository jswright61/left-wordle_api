# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module CloudflareCacheRulesTask
  API_BASE = "https://api.cloudflare.com/client/v4"

  # Every rule shares one action -- "eligible for cache, respect the origin's
  # TTLs" -- so the HTML, client-code and static-asset rules that used to be
  # separate are one rule now. Caddy is where the per-class TTLs live;
  # splitting them here only spent the free plan's 10-rule budget to express
  # the same decision three times. See docs/cache_rules_verification.md.
  CACHEABLE_PATHS = %w[
    /privacy
    /release-notes
    /logins-and-passkeys
    /things-to-test
    /things-to-test-tasks
    /retire-words
    /seed-legacy
    /online-accounts
    /stats-checker
    /app_config.js
    /app_version.js
    /version.json
  ].freeze
  CLIENT_CODE_EXTENSIONS = %w[js css].freeze
  ENVIRONMENT_HOSTS = {
    "prod" => "left-wordle.com",
    "production" => "left-wordle.com",
    "staging" => "staging.left-wordle.com"
  }.freeze
  MANAGED_DESCRIPTION_PREFIX = "Left Wordle - "
  PHASE = "http_request_cache_settings"
  ROOT_ZONE_NAME = "left-wordle.com"
  STATIC_ASSET_EXTENSIONS = %w[png jpg jpeg gif svg ico webp xml txt].freeze
  TOKEN_ENV = "CF_CACHE_RULES_TOKEN"

  module_function

  def api_request(method, path, token:, body: nil, allow_not_found: false)
    uri = URI("#{API_BASE}#{path}")
    request = request_class(method).new(uri)
    request["Accept"] = "application/json"
    request["Authorization"] = "Bearer #{token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    payload = response.body.to_s.empty? ? {} : JSON.parse(response.body)

    return nil if allow_not_found && response.code.to_i == 404

    unless response.is_a?(Net::HTTPSuccess) && payload["success"] != false
      abort "Cloudflare API request failed: #{method.to_s.upcase} #{path} returned HTTP #{response.code}: #{format_errors(payload)}"
    end

    payload.fetch("result", payload)
  rescue JSON::ParserError
    abort "Cloudflare API returned invalid JSON: #{method.to_s.upcase} #{path}"
  end

  def cacheable_action_parameters
    {
      browser_ttl: {mode: "respect_origin"},
      cache: true,
      edge_ttl: {mode: "respect_origin"}
    }
  end

  def cache_rules(environment, host)
    [
      rule(
        environment,
        "bypass_dynamic",
        "Left Wordle - Bypass Dynamic Requests (#{environment})",
        "(http.host eq \"#{host}\" and (starts_with(http.request.uri.path, \"/guesser\") or (starts_with(http.request.uri.path, \"/api/\") and http.request.uri.path ne \"/api/v1/game/answer\")))",
        {cache: false}
      ),
      rule(
        environment,
        "cache_answer_api",
        "Left Wordle - Cache Daily Answer API (#{environment})",
        "(http.host eq \"#{host}\" and http.request.method eq \"GET\" and http.request.uri.path eq \"/api/v1/game/answer\")",
        cacheable_action_parameters
      ),
      rule(
        environment,
        "cache_site_content",
        "Left Wordle - Cache Site Content At Edge (#{environment})",
        site_content_expression(host),
        cacheable_action_parameters
      )
    ]
  end

  def environment_from(args)
    raw = args[:environment].to_s.strip
    raw = ARGV.find { |arg| ENVIRONMENT_HOSTS.key?(arg.to_s.downcase) }.to_s.strip if raw.empty?
    environment = raw.downcase

    return environment if ENVIRONMENT_HOSTS.key?(environment)

    abort usage
  end

  def fetch_entrypoint_ruleset(token, zone_id)
    api_request(:get, "/zones/#{zone_id}/rulesets/phases/#{PHASE}/entrypoint", token: token, allow_not_found: true)
  end

  def format_errors(payload)
    errors = Array(payload["errors"]).map { |error|
      [error["code"], error["message"]].compact.join(": ")
    }.reject(&:empty?)
    errors.empty? ? payload.inspect : errors.join("; ")
  end

  def managed_ref_prefix(environment)
    "left_wordle_#{environment}_"
  end

  def quoted_set(values)
    "{#{values.map { |value| "\"#{value}\"" }.join(" ")}}"
  end

  def request_class(method)
    case method
    when :get
      Net::HTTP::Get
    when :put
      Net::HTTP::Put
    else
      raise ArgumentError, "Unsupported HTTP method: #{method.inspect}"
    end
  end

  def resolve_zone_id(token)
    explicit_zone_id = ENV["CF_ZONE_ID"].to_s.strip
    explicit_zone_id = ENV["CLOUDFLARE_ZONE_ID"].to_s.strip if explicit_zone_id.empty?
    return explicit_zone_id unless explicit_zone_id.empty?

    query = URI.encode_www_form(name: ROOT_ZONE_NAME)
    zones = api_request(:get, "/zones?#{query}", token: token)
    zone = Array(zones).find { |candidate| candidate["name"] == ROOT_ZONE_NAME }

    return zone["id"] if zone && zone["id"].to_s.strip.length.positive?

    abort "Could not find Cloudflare zone #{ROOT_ZONE_NAME.inspect}. Add Zone Read permission or set CF_ZONE_ID."
  end

  def rule(environment, key, description, expression, action_parameters)
    {
      action: "set_cache_settings",
      action_parameters: action_parameters,
      description: description,
      enabled: true,
      expression: expression,
      ref: "#{managed_ref_prefix(environment)}#{key}"
    }
  end

  def run(args)
    environment = environment_from(args)
    host = ENVIRONMENT_HOSTS.fetch(environment)
    token = ENV[TOKEN_ENV].to_s.strip

    abort "#{TOKEN_ENV} is required." if token.empty?

    zone_id = resolve_zone_id(token)
    desired_rules = cache_rules(environment, host)
    existing_ruleset = fetch_entrypoint_ruleset(token, zone_id)
    existing_rules = Array(existing_ruleset && existing_ruleset["rules"])

    # Matched by ref prefix rather than an exact list of the current refs, so
    # that retiring or renaming a rule sweeps its old copy instead of stranding
    # it as "unmanaged" forever -- which is how merging three rules into one
    # would otherwise leave the zone holding both sets.
    unmanaged_rules = existing_rules.reject { |rule|
      description = rule["description"].to_s
      expression = rule["expression"].to_s

      rule["ref"].to_s.start_with?(managed_ref_prefix(environment)) ||
        (description.start_with?(MANAGED_DESCRIPTION_PREFIX) && expression.include?("http.host eq \"#{host}\""))
    }

    # The entrypoint PUT accepts only mutable fields. Do not include response
    # metadata such as kind/name/phase; Cloudflare rejects those as unknown.
    body = {
      rules: unmanaged_rules + desired_rules
    }

    api_request(:put, "/zones/#{zone_id}/rulesets/phases/#{PHASE}/entrypoint", token: token, body: body)

    puts "Updated Cloudflare cache rules for #{host}."
    puts "Managed #{desired_rules.size} rule(s):"
    desired_rules.each { |rule| puts "  #{rule.fetch(:description)}" }
  end

  # /app_version.js and /version.json sit in CACHEABLE_PATHS with everything
  # else because respect_origin is all this rule says: Caddy answers no-cache
  # for those two and s-maxage=31536000 for /app_config.js, and one rule
  # carries both. Without a rule they fall through to the zone's Browser Cache
  # TTL, which rewrites the no-cache to max-age=14400 and can leave a browser
  # four hours behind a release.
  def site_content_expression(host)
    conditions = [
      "http.request.uri.path eq \"/\"",
      "http.request.uri.path.extension eq \"html\"",
      "http.request.uri.path in #{quoted_set(CACHEABLE_PATHS)}",
      "(starts_with(http.request.uri.path, \"/src/\") and http.request.uri.path.extension in #{quoted_set(CLIENT_CODE_EXTENSIONS)})",
      "http.request.uri.path.extension in #{quoted_set(STATIC_ASSET_EXTENSIONS)}"
    ]

    "(http.host eq \"#{host}\" and http.request.method eq \"GET\" and (#{conditions.join(" or ")}))"
  end

  def usage
    <<~TEXT
      Usage:
        CF_CACHE_RULES_TOKEN=... bundle exec rake 'create_cache_rules[staging]'
        CF_CACHE_RULES_TOKEN=... bundle exec rake 'create_cache_rules[prod]'

      Environment must be staging, prod, or production.
    TEXT
  end
end

desc "Create or update Cloudflare cache rules. Usage: rake 'create_cache_rules[staging]'"
task :create_cache_rules, [:environment] do |_task, args|
  CloudflareCacheRulesTask.run(args)
end

# Allows: rake create_cache_rules staging
%w[staging prod production].each { |environment| task environment }
