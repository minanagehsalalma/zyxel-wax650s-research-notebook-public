# Live Summaries Index

These are selected summary artifacts only. They preserve the result boundaries used by the chapters without publishing large traces, raw process state, or private lab material.

## Command Injection

- [admin_web_handler_focus_20260422a](admin_web_handler_focus_20260422a/summary.txt): canonical admin-authenticated `export-cgi` PKCS#12 command-injection replay.
- [admin_cert_export_probe_20260422a](admin_cert_export_probe_20260422a/summary.txt): negative sibling certificate-export probe.

## Cookie And Session Boundary

- [manual_cookie_desync_smoke_20260421b](manual_cookie_desync_smoke_20260421b/summary.txt): live proof that `mod_auth_zyxel` and `zysh-cgi` parse cookie values differently.
- [cookie_desync_backend_compare_20260422e](cookie_desync_backend_compare_20260422e/summary.txt): same-run backend comparison for baseline versus semicolon-suffixed cookie cases.

## Captive Portal Runtime

- [portal_post_increment_refresh_20260422z_retry](portal_post_increment_refresh_20260422z_retry/summary.txt): repaired portal runtime checkpoint.
- [social_login_portal_config_only_20260423a](social_login_portal_config_only_20260423a/quick_summary.txt): `/tmp/portal_config` as the decisive runtime gate on the tested lane.
- [ui_vuln_sweep_20260423as_social_login_stateful_boundary](ui_vuln_sweep_20260423as_social_login_stateful_boundary/summary.txt): social-login acceptance under repaired portal state.
- [ui_vuln_sweep_20260423au_social_login_cp_toggle](ui_vuln_sweep_20260423au_social_login_cp_toggle/summary.txt): `cp_simulate` toggle boundary for the repaired lane.

## Open Redirect

- [ui_vuln_sweep_20260423af_dns_iprep_shaped](ui_vuln_sweep_20260423af_dns_iprep_shaped/summary.txt): request-shape proof that `ext_url` controls redirect destination.
- [ui_vuln_sweep_20260423ai_cp_brand_chain](ui_vuln_sweep_20260423ai_cp_brand_chain/summary.txt): branded captive-portal host behavior for the redirect family.
- [ui_vuln_sweep_20260423ak_iprep_brand_sibling](ui_vuln_sweep_20260423ak_iprep_brand_sibling/summary.txt): sibling `ip_reputation_block.cgi` branded-host confirmation.

## Reading Rule

Treat these summaries as boundary evidence, not exploit scripts. When a summary records a negative result, keep that negative boundary in later reporting unless new live evidence supersedes it.
