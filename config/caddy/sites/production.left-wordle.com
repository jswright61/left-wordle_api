# Production — combined client + API on one domain.
# Deploy to: /etc/caddy/sites-enabled/client_and_api.left-wordle.com
# (Yes, the live filename doesn't match this one's name -- historical,
# not worth renaming on the server just to match. What matters is the
# site address block below.)
prod.left-wordle.com left-wordle.com {
	tls /etc/caddy/certs/origin.pem /etc/caddy/certs/origin.key

	import api-rate-limits unix//home/deploy/left_wordle_api/shared/tmp/sockets/puma.sock
	import strip-html-extension

	handle /guesser* {
		reverse_proxy unix//home/deploy/left_wordle_api/shared/tmp/sockets/puma.sock
	}

	handle {
		root * /home/deploy/left-wordle.com/current
		file_server
		try_files {path} {path}.html {path}/index.html

		# Older blanket cache strategy -- production hasn't been redeployed
		# since staging moved to the per-asset-type s-maxage/Cloudflare-purge
		# approach (see staging.left-wordle.com). Update this to match once
		# production's deploy pipeline is caught up to that change -- see
		# [[cache-control-prod-todo]] memory.
		@html path / *.html
		header @html Cache-Control "no-cache"
	}

	# handle_errors runs its own middleware chain -- it doesn't inherit
	# root or headers from the handle{} block above, so both are repeated
	# here. Scoped to 404 only: a 500 shouldn't claim the page is missing.
	handle_errors 404 {
		root * /home/deploy/left-wordle.com/current
		rewrite * /404.html
		header Cache-Control "no-cache"
		file_server
	}

	log {
		output file /var/log/caddy/left-wordle.log
	}
}
