# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module CloudflareCacheRulesTask
  API_BASE = "https://api.cloudflare.com/client/v4"
  ENVIRONMENT_HOSTS = {
    "prod" => "left-wordle.com",
    "production" => "left-wordle.com",
    "staging" => "staging.left-wordle.com"
  }.freeze
  MANAGED_RULE_COUNT = 5
  PHASE = "http_request_cache_settings"
  ROOT_ZONE_NAME = "left-wordle.com"
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
        "cache_html",
        "Left Wordle - Cache HTML At Edge (#{environment})",
        "(http.host eq \"#{host}\" and http.request.method eq \"GET\" and (http.request.uri.path eq \"/\" or http.request.uri.path.extension eq \"html\" or http.request.uri.path in {\"/privacy\" \"/release-notes\" \"/logins-and-passkeys\" \"/things-to-test\" \"/retire-words\" \"/seed-legacy\" \"/online-accounts\" \"/stats-checker\"}))",
        cacheable_action_parameters
      ),
      rule(
        environment,
        "cache_client_code",
        "Left Wordle - Cache Client Code At Edge (#{environment})",
        "(http.host eq \"#{host}\" and http.request.method eq \"GET\" and ((http.request.uri.path eq \"/app_config.js\") or (starts_with(http.request.uri.path, \"/src/\") and http.request.uri.path.extension in {\"js\" \"css\"})))",
        cacheable_action_parameters
      ),
      rule(
        environment,
        "cache_static_assets",
        "Left Wordle - Cache Static Assets (#{environment})",
        "(http.host eq \"#{host}\" and http.request.method eq \"GET\" and http.request.uri.path.extension in {\"png\" \"jpg\" \"jpeg\" \"gif\" \"svg\" \"ico\" \"webp\" \"xml\" \"txt\"})",
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
      ref: "left_wordle_#{environment}_#{key}"
    }
  end

  def run(args)
    environment = environment_from(args)
    host = ENVIRONMENT_HOSTS.fetch(environment)
    token = ENV[TOKEN_ENV].to_s.strip

    abort "#{TOKEN_ENV} is required." if token.empty?

    zone_id = resolve_zone_id(token)
    desired_rules = cache_rules(environment, host)
    managed_base_descriptions = desired_rules.map { |rule| rule.fetch(:description).delete_suffix(" (#{environment})") }
    managed_descriptions = desired_rules.map { |rule| rule.fetch(:description) }
    managed_refs = desired_rules.map { |rule| rule.fetch(:ref) }
    existing_ruleset = fetch_entrypoint_ruleset(token, zone_id)
    existing_rules = Array(existing_ruleset && existing_ruleset["rules"])
    unmanaged_rules = existing_rules.reject { |rule|
      description = rule["description"].to_s
      expression = rule["expression"].to_s

      managed_refs.include?(rule["ref"]) ||
        managed_descriptions.include?(description) ||
        (managed_base_descriptions.include?(description) && expression.include?("http.host eq \"#{host}\""))
    }

    # The entrypoint PUT accepts only mutable fields. Do not include response
    # metadata such as kind/name/phase; Cloudflare rejects those as unknown.
    body = {
      rules: unmanaged_rules + desired_rules
    }

    api_request(:put, "/zones/#{zone_id}/rulesets/phases/#{PHASE}/entrypoint", token: token, body: body)

    puts "Updated Cloudflare cache rules for #{host}."
    puts "Managed #{MANAGED_RULE_COUNT} rule(s):"
    desired_rules.each { |rule| puts "  #{rule.fetch(:description)}" }
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
