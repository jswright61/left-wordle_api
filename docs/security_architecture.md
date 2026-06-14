# Security Architecture

This document describes the intended security boundaries for Left Wordle and
Left Wordle API. It distinguishes the controls currently implemented by the API
from the controls recommended for deployment and future authenticated features.

## Guiding Principles

- Treat CORS as a browser policy, not authentication or API protection.
- Keep the application secure even if a proxy or edge rule is bypassed.
- Use separate controls for public browser traffic and private service traffic.
- Authenticate every request that reads or changes private user data.
- Authorize access to each record after authenticating the caller.
- Minimize the privileges granted to internal services.
- Use exact hostnames and origins rather than broad subdomain patterns.

## Hostname Model

The frontend and API may be deployed as separate applications:

```text
Frontend: https://left-wordle.example.com
API:      https://api.left-wordle.example.com
```

This is a reasonable design. The two URLs are different origins but are the
same site when both use HTTPS under the same registrable domain. The separation
adds CORS and cookie configuration, but it preserves a clear application
boundary.

A same-origin deployment is simpler:

```text
Frontend: https://left-wordle.example.com/
API:      https://left-wordle.example.com/api/
```

Either model is valid. The separate-origin model should be retained when the
operational and architectural separation is worth the additional configuration.

## CORS

CORS determines which browser origins may read API responses. It does not stop
non-browser clients, scripts, command-line tools, or malicious clients from
making requests. An attacker can omit or forge the `Origin` header.

The API uses a comma-separated exact-origin allowlist:

```zsh
CORS_ORIGINS=https://left-wordle.example.com,https://alternate.example.com
```

Current behavior:

- An approved browser origin is echoed in `Access-Control-Allow-Origin`.
- An unapproved supplied origin receives `403 Forbidden`.
- No browser origins are allowed by default.
- Requests without an `Origin` header remain available to server-to-server
  clients.
- Responses include `Vary: Origin` to prevent caches from mixing CORS results.

The public site's own origin must be included because browsers can send
`Origin` on same-origin requests, particularly non-GET requests.

When bearer-token authentication is added, `Authorization` must be included in
`Access-Control-Allow-Headers`. When cross-origin cookie authentication is
used, responses must also include `Access-Control-Allow-Credentials: true`, and
the frontend must use `fetch` with `credentials: "include"`. A wildcard origin
cannot be used with credentialed CORS.

## Layered Deployment

No single component should be responsible for the entire security posture.

### Cloudflare

Cloudflare should protect the public hostname before requests reach the server:

- Proxy public DNS through Cloudflare.
- Enable the available managed WAF protections.
- Add rate limiting for abuse-prone API routes.
- Use bot or challenge rules where they do not disrupt legitimate API clients.
- Monitor security events and unusual traffic patterns.

Cloudflare Tunnel is preferred when practical. The origin initiates outbound
connections to Cloudflare, allowing public inbound access to the origin to be
blocked. This prevents attackers from bypassing Cloudflare after discovering
the origin IP address.

If a conventional public origin is used instead, its firewall should accept
public HTTP traffic only from Cloudflare's published address ranges. The
Tailscale interface remains a separate private path.

Cloudflare's free-plan rate limiting is useful but limited. It should reduce
bulk abuse rather than serve as the application's only throttling mechanism.

### Caddy

Caddy should provide the origin-facing HTTP boundary:

- Terminate TLS when it is not terminated by a local tunnel connection.
- Reverse proxy requests to the Sinatra process on a loopback or Unix socket.
- Apply request-body size limits.
- Set reasonable header, body, write, and idle timeouts.
- Reject unexpected hostnames.
- Produce structured access logs without recording secrets or session tokens.
- Optionally separate public and Tailscale listeners or hostnames.

Forwarded client IP headers must be trusted only when the immediate peer is a
known proxy. Caddy trusts no proxies by default. If Cloudflare connects directly
to Caddy, configure Cloudflare's current IP ranges as trusted proxies and use
strict right-to-left forwarded-address parsing. Never trust arbitrary
`X-Forwarded-For` values from the public Internet.

### Sinatra

The application remains the final authority and must implement:

- Strict request validation and bounded payload sizes.
- Exact CORS origin validation.
- Authentication and session validation.
- Per-record authorization.
- WebAuthn challenge and assertion verification.
- CSRF protection where cookies authenticate requests.
- Endpoint-specific and per-account throttling.
- Generic authentication errors that do not disclose account existence.
- Safe logging that excludes credentials, challenges, tokens, and private game
  data.

Edge and proxy controls reduce load and exposure, but application security must
not depend on them being configured perfectly.

## WebAuthn and Passkeys

WebAuthn does not require the backend server to have the same hostname as the
frontend. It cares about the browser origin that invokes WebAuthn and the
Relying Party ID to which credentials are scoped.

For the separate-host deployment, use:

```text
Frontend origin: https://left-wordle.example.com
API hostname:    https://api.left-wordle.example.com
RP ID:           left-wordle.example.com
```

The browser invokes WebAuthn from the frontend origin. The API creates
challenges and verifies the resulting registration or authentication data.
During verification, it must require:

- RP ID exactly equal to `left-wordle.example.com`.
- Origin exactly equal to `https://left-wordle.example.com`.
- The expected challenge generated for that ceremony.
- User verification when required by policy.
- A credential ID registered to the expected account.
- A valid signature and authenticator data.

Do not accept every subdomain origin merely because the RP ID is the parent
domain. Untrusted code on an accepted subdomain can undermine passkey security.

Challenges must be cryptographically random, short-lived, single-use, and
stored server-side until verification. Registration and authentication
endpoints require aggressive rate limiting. Users should be able to register
multiple passkeys and review or revoke them.

Select the permanent RP ID before production registration. Credentials remain
bound to that RP ID and cannot be freely moved to an unrelated domain later.

## Sessions, Cookies, and CSRF

After successful passkey authentication, the API should establish an
application session. For browser clients, an opaque server-side session with a
cookie is preferred over exposing a long-lived token to JavaScript.

Recommended cookie properties:

```text
Secure
HttpOnly
Path=/
SameSite=Lax or Strict when compatible with the final flow
```

Keep the cookie host-only on `api.left-wordle.example.com`. Avoid setting
`Domain=left-wordle.example.com` unless another trusted subdomain genuinely
needs to receive it.

Because the frontend and API are separate origins, browser requests must use
credentialed CORS. Even though the hosts are normally same-site, state-changing
cookie-authenticated requests should use explicit CSRF protection. A practical
design is a session-bound CSRF token sent in a custom request header and checked
by the API. Also validate `Origin` on authenticated browser requests.

Session records should support expiration, rotation after authentication,
revocation, and logout. Sensitive account changes should require recent user
verification.

## User Data Authorization

Game state and history are private user data once server storage is introduced.
Every storage operation must derive the user identity from the authenticated
session rather than accepting a user ID supplied by the client.

Required rules include:

- A user can read and modify only their own state and history.
- Puzzle and history identifiers are validated independently of ownership.
- Bulk import endpoints have count and body-size limits.
- Conflicts and synchronization rules are deterministic and tested.
- Database uniqueness constraints reinforce application authorization and data
  integrity assumptions.
- Administrative operations use separate authorization, routes, and audit
  logging.

Passkey credential IDs and public keys are authentication data. They should not
be exposed through ordinary profile or game APIs.

## Public Gameplay Endpoint

The current guess endpoint is public and stateless. CORS does not prevent an
automated client from probing it. A caller can submit many valid words and use
the evaluations to infer an answer without obeying the browser's six-guess
limit.

Possible future policies are:

- Accept that the puzzle API is public and rate limit only for resource abuse.
- Require an anonymous server-issued attempt token and enforce six guesses.
- Require an authenticated session and store authoritative attempt state.

The appropriate choice depends on whether preventing automated answer discovery
is a product requirement. Regardless of that decision, enforce request-rate,
body-size, and execution-time limits to protect resources.

## WordleGuesser over Tailscale

WordleGuesser should use a private route rather than the public Cloudflare
hostname:

```text
WordleGuesser -> Tailscale -> private Caddy listener -> Sinatra
```

Assign stable device tags, for example:

```text
tag:wordle-guesser
tag:left-wordle-api
```

Use Tailscale grants to allow only `tag:wordle-guesser` to reach the API
device's private service port. Tailscale policies are deny-by-default, so no
broader tailnet access needs to be granted.

Tailscale authenticates the device and protects the network path, but the API
should also authenticate WordleGuesser at the application layer. Give it a
dedicated, narrowly scoped service credential that can call only the endpoints
it requires. Store the credential outside the repository and support rotation
and revocation.

Do not treat the absence of an `Origin` header as authentication. It merely
distinguishes typical server clients from browser CORS requests and is trivial
to imitate.

Possible service authentication mechanisms include:

- A random bearer token stored as a hash by the API.
- A signed short-lived token issued specifically for WordleGuesser.
- Mutual TLS on the private listener if operational complexity is justified.

A scoped bearer token over Tailscale is an appropriate initial design.

## Rate Limiting

Apply limits at multiple layers because each layer sees different identities:

- Cloudflare: public source IP and broad attack patterns.
- Caddy: connections, request sizes, slow clients, and coarse source limits.
- Sinatra: route, authenticated user, session, service credential, and action.

Authentication endpoints should have stricter limits than ordinary puzzle
metadata. Rate-limit both challenge creation and failed verification. Limits
should avoid revealing whether an account or credential exists.

Rate limiting is a resource and abuse control, not authorization. Legitimate
requests must still be authenticated and authorized.

## Operational Controls

- Keep Ruby, Sinatra, Caddy, and system packages patched.
- Run the application as an unprivileged service account.
- Bind Puma only to loopback, a Unix socket, or a specifically protected
  interface.
- Store secrets in environment-specific secret management, not Git.
- Back up the database and test restoration.
- Encrypt backups and restrict their retention and access.
- Monitor authentication failures, unusual request rates, and authorization
  failures.
- Avoid logging cookies, bearer tokens, WebAuthn challenges, assertions, or
  private user data.
- Return generic production errors without stack traces.
- Maintain a documented credential and incident-response rotation procedure.

## Suggested Implementation Order

1. Finalize public frontend, API, and WebAuthn RP ID hostnames.
2. Deploy the public API behind Cloudflare and Caddy without exposing Puma.
3. Add proxy timeouts, body limits, logging, and origin firewall restrictions.
4. Configure the exact CORS allowlist for the production frontend.
5. Add database-backed users, passkey credentials, challenges, and sessions.
6. Add CSRF protection and authenticated game state/history authorization.
7. Add application-level rate limiting for authentication and storage routes.
8. Add the private Tailscale listener and scoped WordleGuesser credential.
9. Add monitoring, backup restoration tests, and security regression tests.

## References

- [Cloudflare rate limiting](https://developers.cloudflare.com/waf/rate-limiting-rules/)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- [Cloudflare origin protection](https://developers.cloudflare.com/fundamentals/concepts/cloudflare-ip-addresses/)
- [Caddy request matchers](https://caddyserver.com/docs/caddyfile/matchers)
- [Caddy trusted proxies](https://caddyserver.com/docs/caddyfile/options#trusted-proxies)
- [Tailscale policy syntax](https://tailscale.com/docs/reference/syntax/policy-file)
- [WebAuthn Level 3](https://www.w3.org/TR/webauthn-3/)
