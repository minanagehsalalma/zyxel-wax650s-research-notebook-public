# 08 - Captive Portal Open Redirect Family

## Claim

`dns_filter.cgi` and `ip_reputation_block.cgi` expose a pre-auth open redirect family. A syntactically valid `host=` value can be paired with attacker-controlled `ext_url=`, and the handler returns a `302 Location` to the attacker-controlled destination.

## Why This Is Device-Specific

This is stronger than a generic low-value open redirect because the product is built around captive-portal redirection. The believable delivery path is:

1. Victim sees a Zyxel/Nebula captive-portal URL.
2. The request uses a branded captive-portal host such as `nap-slogin.nebula.zyxel.com`.
3. The device issues a server-side `302`.
4. The browser lands on the attacker-controlled continuation page.

The bug abuses the product's own trust pattern: users expect captive portals to redirect.

## Affected Handlers

- `/cgi-bin/dns_filter.cgi`
- `/cgi-bin/ip_reputation_block.cgi`

They are best treated as one CWE-601 family by default:

- same auth boundary
- same `host` and `ext_url` input model
- same `Location:` sink shape
- same policy model for external block-page URI behavior
- feature-specific wrapper differences only

## Reproduction Shape

The clean PoC is preserved under [artifacts/open-redirect-poc](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/open-redirect-poc/).

The report package also preserves:

- [REPORT.md](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/open-redirect/REPORT.md)
- [POC_URLS.md](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/open-redirect/POC_URLS.md)
- [ARTIFACTS.md](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/open-redirect/ARTIFACTS.md)

The PoC intentionally uses a benign continuation page with disabled form controls. It demonstrates realistic captive-portal trust without becoming a credential-harvesting kit.

## Browser Execution Boundary

The live HTTP layer reflected destinations such as `javascript:` and `data:` into the `Location` header in raw responses. That is not the same as browser JavaScript execution.

The promoted claim stays at:

- pre-auth arbitrary redirect
- branded captive-portal delivery
- policy URL override
- phishing/trust abuse and redirect-chain utility

The promoted claim does not say:

- server-side redirect creates XSS in Chrome
- account takeover was proved
- OAuth token theft was proved against this product

## Evidence Files

- [artifacts/live-summaries/ui_vuln_sweep_20260423ai_cp_brand_chain/summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/ui_vuln_sweep_20260423ai_cp_brand_chain/summary.txt)
- [artifacts/live-summaries/ui_vuln_sweep_20260423ak_iprep_brand_sibling/summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/ui_vuln_sweep_20260423ak_iprep_brand_sibling/summary.txt)
- [artifacts/live-summaries/ui_vuln_sweep_20260423af_dns_iprep_shaped/summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/ui_vuln_sweep_20260423af_dns_iprep_shaped/summary.txt)
- [artifacts/reports/open-redirect/dynamic/dns_iprep_boundary_summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/open-redirect/dynamic/dns_iprep_boundary_summary.txt)
- [artifacts/reports/open-redirect/REPORT.md](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/open-redirect/REPORT.md)
