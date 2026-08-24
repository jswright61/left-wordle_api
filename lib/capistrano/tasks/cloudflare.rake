# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"

module CloudflarePurgeCredentials
  # Not a secret -- identifies which zone an API call applies to (visible in
  # the Cloudflare dashboard URL) and grants no capability on its own. Only
  # the API token below does.
  ZONE_ID = "8111259d817302b1c2a208e940e407b2"
  KEYCHAIN_SERVICE = "CF_PURGE_CACHE_TOKEN"

  module_function

  # Add the token with:
  #   security add-generic-password -a "$USER" -s "CF_PURGE_CACHE_TOKEN" -w 'YOUR_TOKEN_HERE'
  def api_token
    stdout, status = Open3.capture2(
      "security", "find-generic-password",
      "-a", ENV.fetch("USER", ""), "-s", KEYCHAIN_SERVICE, "-w"
    )
    status.success? ? stdout.strip : nil
  end
end

namespace :deploy do
  desc "Purge Cloudflare cache after a successful deploy"
  task :purge_cloudflare_cache do
    api_token = CloudflarePurgeCredentials.api_token
    if api_token.to_s.empty?
      abort <<~MSG
        Cloudflare purge failed: no "#{CloudflarePurgeCredentials::KEYCHAIN_SERVICE}" entry in Keychain.
        Add it with:
          security add-generic-password -a "$USER" -s "#{CloudflarePurgeCredentials::KEYCHAIN_SERVICE}" -w 'YOUR_TOKEN_HERE'
      MSG
    end

    uri = URI("https://api.cloudflare.com/client/v4/zones/#{CloudflarePurgeCredentials::ZONE_ID}/purge_cache")
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
