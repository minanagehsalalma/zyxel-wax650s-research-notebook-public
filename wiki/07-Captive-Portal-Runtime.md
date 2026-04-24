# 07 - Captive Portal Runtime

The captive portal work mattered for two reasons:

- it exposed a real pre-auth redirect family
- it forced the lab to model dynamic runtime state instead of only static files

## Runtime State Problem

Several portal CGIs returned `HTTP 500` until expected runtime state existed. The decisive state included `/tmp/portal_config`, `portal_info`, and `whybrid`.

The important result was a narrow one:

- restoring only `/tmp/portal_config` could move a non-bootstrap lane from `500` into real backend `Clicktocontinue.cgi` success and real backend `social_login.cgi` acceptance
- `cp_simulate` was not the meaningful request-time gate after the repaired lane was alive
- the decisive blob was still lab-written on the strongest non-bootstrap test

## `social_login.cgi` Boundary

The social login path is interesting but not promoted as a standalone auth bypass.

Observed:

- shipped frontend `userdata.html` parses Facebook token data in browser JS
- it submits only `fb_user` to `/cgi-bin/social_login.cgi`
- repaired lanes showed cases where arbitrary `fb_user` was accepted and a token-like body line was produced
- backend logs and strace showed real UAM notifications in some runs

Not proved:

- clean stock portal runtime generation without lab repair
- stable browser-valid guest cookie issuance from the HTTP headers
- server-side Facebook token verification bypass on a faithful product lane

## Evidence Files

- [artifacts/live-summaries/portal_post_increment_refresh_20260422z_retry/summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/portal_post_increment_refresh_20260422z_retry/summary.txt)
- [artifacts/live-summaries/social_login_portal_config_only_20260423a/quick_summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/social_login_portal_config_only_20260423a/quick_summary.txt)
- [artifacts/live-summaries/ui_vuln_sweep_20260423au_social_login_cp_toggle/summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/ui_vuln_sweep_20260423au_social_login_cp_toggle/summary.txt)
- [artifacts/live-summaries/ui_vuln_sweep_20260423as_social_login_stateful_boundary/summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/ui_vuln_sweep_20260423as_social_login_stateful_boundary/summary.txt)

## Rule For Future Work

Do not promote the social-login path until it is reproduced on a non-synthetic portal bring-up or until static reversing identifies a product-real source for the same backend state.
