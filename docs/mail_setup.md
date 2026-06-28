# Mail Setup for Diagnostics Endpoint

The `POST /api/v1/diagnostics` endpoint receives a JSON payload from the client and emails it as an attachment to the Left Wordle support address. Mail is sent via Fastmail using SMTP with STARTTLS.

## How It Works

When a user clicks "Send Settings to Developers" in the Tools panel, the client collects all `localStorage` keys and POSTs them to `POST /api/v1/diagnostics`. The API validates the payload, then calls `send_diagnostics_email` which delivers a `.json` attachment to `left.wordle@wrightzone.com`.

The endpoint returns 503 with a descriptive error if SMTP is not configured, so the client can prompt the user to use "Download All Settings" instead.

## Configuration

All mail settings live in `config/app_config.yml` (gitignored). The sample file at `config/app_config.yml.sample` shows the expected keys:

```yaml
smtp_username: your_fastmail_address@fastmail.com
smtp_password: your_app_specific_password
# smtp_from: optional_from_override@example.com
```

| Key | Required | Notes |
|-----|----------|-------|
| `smtp_username` | Yes | The Fastmail account address. Also used as the `From:` address when `smtp_from` is omitted. |
| `smtp_password` | Yes | An **app-specific password** from Fastmail — not your login password. |
| `smtp_from` | No | Overrides the `From:` address if you want mail to appear from a different address than the SMTP login. |

If either `smtp_username` or `smtp_password` is missing or blank, `smtp_configured?` returns false and the endpoint responds 503 without attempting delivery.

## Creating a Fastmail App Password

1. Log in to Fastmail → Settings → Privacy & Security → App Passwords.
2. Click "New App Password".
3. Name it something like `left-wordle-diagnostics`.
4. Set scope to "Mail (SMTP only)" if available, or leave it as full access.
5. Copy the generated password into `smtp_password` in `app_config.yml`.

## SMTP Settings (hardcoded)

```
Host:      smtp.fastmail.com
Port:      587
Auth:      PLAIN
TLS:       STARTTLS (auto)
```

These are the standard Fastmail SMTP settings and are hardcoded in `send_diagnostics_email`. If you ever switch providers, update that method in `app.rb`.

## Test Environment

In `RACK_ENV=test`, the mail gem's `:test` delivery method is used — no email is actually sent. Delivery can be inspected via `Mail::TestMailer.deliveries` in tests.

## Updating the Config on the Server

`app_config.yml` is managed as a Capistrano shared file. To update credentials:

```bash
# SSH to the server and edit the shared config directly
nano /home/deploy/<deploy_path>/shared/config/app_config.yml
# Then restart Puma to reload the config
sudo systemctl restart puma  # or your service name
```

The next deploy will symlink the updated file into the release automatically.
