# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"

module CloudflarePurgeCredentials
  ONE_PASSWORD_ITEM_UUID = "k46hfgro7uxkxtsivzqoohobzy"
  PURGE_TOKEN_ENV_KEYS = ["CF_PURGE_CACHE_TOKEN", "CLOUDFLARE_API_TOKEN"].freeze
  ZONE_ID_ENV_KEYS = ["CF_ZONE_ID", "CLOUDFLARE_ZONE_ID"].freeze

  module_function

  def fetch
    credentials = from_one_password
    return credentials if credentials_complete?(credentials)

    from_env
  end

  def field_value(item, label)
    field = Array(item["fields"]).find { |candidate| candidate["label"] == label }
    field && field["value"].to_s.strip
  end

  def from_env
    {
      api_token: first_env_value(PURGE_TOKEN_ENV_KEYS),
      zone_id: first_env_value(ZONE_ID_ENV_KEYS)
    }
  end

  def from_one_password
    stdout, status = Open3.capture2e(
      "op",
      "item",
      "get",
      ONE_PASSWORD_ITEM_UUID,
      "--format",
      "json",
      "--reveal"
    )
    return {} unless status.success?

    item = JSON.parse(stdout)
    {
      api_token: field_value(item, "CF_PURGE_CACHE_TOKEN"),
      zone_id: field_value(item, "CF_ZONE_ID")
    }
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  def credentials_complete?(credentials)
    credentials[:api_token].to_s.strip.length.positive? &&
      credentials[:zone_id].to_s.strip.length.positive?
  end

  def first_env_value(keys)
    keys.map { |key| ENV[key].to_s.strip }.find { |value| value.length.positive? }.to_s
  end
end

namespace :deploy do
  desc "Purge Cloudflare cache after a successful deploy"
  task :purge_cloudflare_cache do
    credentials = CloudflarePurgeCredentials.fetch
    api_token = credentials[:api_token].to_s.strip
    zone_id = credentials[:zone_id].to_s.strip

    if api_token.empty? || zone_id.empty?
      puts "  Skipping Cloudflare purge: 1Password item missing and CF_ZONE_ID/CF_PURGE_CACHE_TOKEN not set"
      next
    end

    uri = URI("https://api.cloudflare.com/client/v4/zones/#{zone_id}/purge_cache")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{api_token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(purge_everything: true)

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    body = JSON.parse(response.body)

    unless response.is_a?(Net::HTTPSuccess) && body["success"] == true
      abort "Cloudflare purge failed: HTTP #{response.code} #{response.body}"
    end

    puts "  Cloudflare cache purge requested"
  rescue JSON::ParserError
    abort "Cloudflare purge failed: invalid API response"
  end
end
