# Staging — combined client + API on one domain.
# Deploy to: /etc/caddy/sites-enabled/staging.left-wordle.com
staging.left-wordle.com {
	tls /etc/caddy/certs/origin.pem /etc/caddy/certs/origin.key

	import api-rate-limits unix//home/deploy/staging_left_wordle_api/shared/tmp/sockets/puma.sock
	import strip-html-extension

	# The snippet is defined for every site by the global snippets import, but
	# it does nothing until a site block invokes it -- which is why dotfiles
	# were served here for as long as the snippet has existed. It carves out
	# /.well-known/* so ACME and passkey paths still resolve. Position within
	# this block is cosmetic: Caddy sorts the snippet's matcher-bearing handle
	# ahead of the bare catch-all below no matter where the import appears.
	import hide-dot-files

	handle /guesser* {
		reverse_proxy unix//home/deploy/staging_left_wordle_api/shared/tmp/sockets/puma.sock
	}

	handle {
		root * /home/deploy/staging.left-wordle.com/current
		try_files {path} {path}.html {path}/index.html

		# Mutable app files rely on browser revalidation plus Cloudflare purge
		# at deploy time. s-maxage lets Cloudflare keep the edge hot without
		# asking browsers to keep stale copies after a release.
		@html path / *.html /privacy /release-notes /logins-and-passkeys /things-to-test /things-to-test-tasks /retire-words /seed-legacy /online-accounts /stats-checker
		header @html Cache-Control "public, max-age=0, s-maxage=7200, must-revalidate"

		# Deliberately NOT covered by a bare *.js wildcard: a wildcard that
		# matched /app_version.js would override this no-cache and the app
		# could stop noticing new releases. Every stylesheet and script now
		# lives under /src/, so @clientCode never reaches this file.
		@releaseMarkers path /app_version.js /version.json
		header @releaseMarkers Cache-Control "no-cache"

		@clientCode path /app_config.js /src/*.js /src/*.css
		header @clientCode Cache-Control "public, max-age=0, s-maxage=31536000, must-revalidate"

		@staticAssets path *.png *.jpg *.jpeg *.gif *.svg *.ico *.webp *.xml *.txt
		header @staticAssets Cache-Control "public, max-age=86400, s-maxage=2592000"

		file_server
	}

	# handle_errors runs its own middleware chain -- it doesn't inherit
	# root or headers from the handle{} block above, so both are repeated
	# here. Scoped to 404 only: a 500 shouldn't claim the page is missing.
	handle_errors 404 {
		root * /home/deploy/staging.left-wordle.com/current
		rewrite * /404.html
		header Cache-Control "public, max-age=0, s-maxage=7200, must-revalidate"
		file_server
	}

	log {
		output file /var/log/caddy/left-wordle-staging.log
	}
}
