# Staging — combined client + API on one domain.
# Deploy to: /etc/caddy/sites-enabled/staging.left-wordle.com
staging.left-wordle.com {
	tls /etc/caddy/certs/origin.pem /etc/caddy/certs/origin.key

	import api-rate-limits unix//home/deploy/staging_left_wordle_api/shared/tmp/sockets/puma.sock

	handle {
		root * /home/deploy/staging.left-wordle.com/current
		file_server
		try_files {path} {path}.html {path}/index.html
	}

	log {
		output file /var/log/caddy/left-wordle-staging.log
	}
}
