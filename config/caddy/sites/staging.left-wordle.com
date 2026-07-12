# Staging — combined client + API on one domain.
# Deploy to: /etc/caddy/sites-enabled/staging.left-wordle.com
staging.left-wordle.com {
	tls /etc/caddy/certs/origin.pem /etc/caddy/certs/origin.key

	import api-rate-limits unix//home/deploy/staging_left_wordle_api/shared/tmp/sockets/puma.sock

	handle {
		root * /home/deploy/staging.left-wordle.com/current
		file_server
		try_files {path} {path}.html {path}/index.html

		# index.html references hashed asset URLs (?v=<content-hash>, set by
		# deploy:write_app_config) that are safe to cache forever -- but
		# index.html itself has no such busting and must always revalidate,
		# or browsers can keep serving a stale copy (with stale asset
		# references, e.g. an outdated api_base_url) via HTTP heuristic
		# caching long after a new deploy.
		@html path / *.html
		header @html Cache-Control "no-cache"
	}

	log {
		output file /var/log/caddy/left-wordle-staging.log
	}
}
