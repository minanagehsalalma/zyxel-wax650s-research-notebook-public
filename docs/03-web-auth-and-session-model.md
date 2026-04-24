# 03 - Web Auth And Session Model

The web auth model split into three separate decision points.

## Layer 1: `mod_auth_zyxel`

`mod_auth_zyxel` gates HTTP access before CGI execution. It decides whether the request is allowed to reach a handler and whether a path is skipped by no-auth configuration.

This layer is important for:

- no-cookie behavior
- guest versus admin cookie behavior
- `AuthZyxelSkipPattern` routes
- captive portal no-auth routes

The open redirect finding depends on this layer because `dns_filter.cgi` and `ip_reputation_block.cgi` are reachable pre-auth.

## Layer 2: CGI-Specific Session Parsing

Some CGI handlers parse request state again after `mod_auth_zyxel` has already allowed the request. This created the most important parser mismatch:

- the front auth layer accepted a trimmed or first-token view
- `zysh-cgi` later received a different unsplit cookie value
- the backend user lookup could miss and enter a fallback branch

This is documented in [Cookie Parser Mismatch](04-cookie-parser-mismatch.md).

## Layer 3: Backend Command Completion

`zysh-cgi` is not the final authority. It stages command data and talks to backend CLI machinery. The backend may still deny, hang, or fail to flush output.

That is why the notebook uses two layers of impact language:

- proven: CGI-layer RBAC/session handling is not strict and can dispatch into backend paths
- not proven: guest web session completes arbitrary admin CLI task on this build

## Browser Token Boundary

Several tests proved that manually seeded backend tokens are not the same as browser-valid sessions. For example, `authtok=admin0` could be meaningful to a backend test harness but still fail to open the authenticated ExtJS shell in a browser route.

The rule used throughout the project:

If a result depends on a synthetic token, call it a backend or handler proof, not a browser-auth proof.

