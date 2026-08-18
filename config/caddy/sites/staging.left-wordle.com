# Staging — combined client + API on one domain.
# Deploy to: /etc/caddy/sites-enabled/staging.left-wordle.com
staging.left-wordle.com {
	tls /etc/caddy/certs/origin.pem /etc/caddy/certs/origin.key

	import api-rate-limits unix//home/deploy/staging_left_wordle_api/shared/tmp/sockets/puma.sock

	handle {
		root * /home/deploy/staging.left-wordle.com/current
		try_files {path} {path}.html {path}/index.html

		# Mutable app files rely on browser revalidation plus Cloudflare purge
		# at deploy time. s-maxage lets Cloudflare keep the edge hot without
		# asking browsers to keep stale copies after a release.
		@html path / *.html /privacy /release-notes /logins-and-passkeys /things-to-test /retire-words /seed-legacy
		header @html Cache-Control "public, max-age=0, s-maxage=7200, must-revalidate"

		@releaseMarkers path /app_version.js /version.json
		header @releaseMarkers Cache-Control "no-cache"

		@clientCode path /app_config.js /src/*.js /src/*.css /things-to-test.css
		header @clientCode Cache-Control "public, max-age=0, s-maxage=31536000, must-revalidate"

		@staticAssets path *.png *.jpg *.jpeg *.gif *.svg *.ico *.webp *.xml *.txt
		header @staticAssets Cache-Control "public, max-age=86400, s-maxage=2592000"

		file_server
	}

	log {
		output file /var/log/caddy/left-wordle-staging.log
	}
}
