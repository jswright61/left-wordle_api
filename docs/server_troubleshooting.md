# Server Toubleshooting

## Caddy Commands
```zsh
# reload running Caddy with updated config
systemctl reload caddy
# Is the Caddy Service active?
systemctl is-active caddy
# Validate Caddy config
caddy validate --config /etc/caddy/Caddyfile
```

## API Puma Service Commands
```zsh
# is the Puma service for the Prod API running
systemctl is-active left-wordle-api
# basically tails the logs for Prod Puma
journalctl -u left-wordle-api -n 30 -l --no-pager
# restart prod API puma service
systemctl reload-or-restart left-wordle-api
# Start prod API puma service
systemctl start left-wordle-api
# Sop prod API puma service
systemctl stop left-wordle-api
# Pick up new configs for systemd services
systemctl daemon-reload
# what's the status of the API Puma service
systemctl status left-wordle-api
```
Note Staging API Puma sever is left-wordle-api-staging