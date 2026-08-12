# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

namespace :deploy do
  desc "Purge Cloudflare cache after a successful deploy"
  task :purge_cloudflare_cache do
    api_token = ENV["CLOUDFLARE_API_TOKEN"].to_s.strip
    zone_id = ENV["CLOUDFLARE_ZONE_ID"].to_s.strip

    if api_token.empty? || zone_id.empty?
      puts "  Skipping Cloudflare purge: CLOUDFLARE_ZONE_ID/CLOUDFLARE_API_TOKEN not set"
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

after "puma:restart", "deploy:purge_cloudflare_cache"
