# Final Findings Summary

Target: Zyxel WAX650S firmware `V7.10(ABRM.4)C0`

Firmware SHA-256: `e0a93db912c0b7203e0eb899f07ddef99b62a82a27352477c0f85d761576b1e0`

This summary captures the public-safe finding boundaries. It intentionally avoids private disclosure correspondence and superseded high-impact drafts.

## Promoted Findings

### 1. Admin-Authenticated PKCS#12 Export Command Injection

The `export-cgi` PKCS#12 export path builds a shell command from user-controlled export parameters. A valid admin web session can reach the handler and a quote-breaking password argument produced live command execution in the lab CGI context.

Confirmed impact:

- admin-authenticated command injection;
- live HTTP response included command output marker;
- exposed UI code maps to the same export path.

Boundary:

- not pre-auth;
- not proved with guest or no-cookie access;
- host UID in the lab is an emulation artifact and should not be used to infer hardware UID.

Primary evidence:

- [admin_web_handler_focus_20260422a](../live-summaries/admin_web_handler_focus_20260422a/summary.txt)
- [finding2_cmdi_transcript.txt](finding2_cmdi_transcript.txt)

### 2. Reversible Zyxel `$4$` Password Material

The firmware stores or processes Zyxel `$4$` password material in a reversible form. Static analysis and supporting offsets identify the decryption path and key material used to recover plaintext from encrypted configuration material.

Confirmed impact:

- plaintext password recovery from obtained encrypted material;
- useful for post-disclosure validation and configuration-risk assessment.

Boundary:

- requires access to encrypted material;
- not a standalone remote exploit by itself.

Primary evidence:

- [disassembly_key_offsets.txt](disassembly_key_offsets.txt)

### 3. `zysh-cgi` Cookie/Session Parser Mismatch

`mod_auth_zyxel` and `zysh-cgi` do not interpret the same cookie string identically. A request accepted by the outer web-auth layer can reach `zysh-cgi` with an unsplit cookie suffix, driving the CGI into its missing-user fallback and changing the staged CLI prelude.

Confirmed impact:

- handler-level parser mismatch;
- guest-authenticated requests can reach the real `zysh-cgi` path;
- backend dumps show the unsplit cookie value and admin-type fallback text.

Boundary:

- final guest administrative command completion was not reproduced;
- report this as a bounded authorization/session parsing flaw, not as full device takeover.

Primary evidence:

- [Zyxel_zysh_cgi_rbac_assessment.md](Zyxel_zysh_cgi_rbac_assessment.md)
- [manual_cookie_desync_smoke_20260421b](../live-summaries/manual_cookie_desync_smoke_20260421b/summary.txt)
- [cookie_desync_backend_compare_20260422e](../live-summaries/cookie_desync_backend_compare_20260422e/summary.txt)

### 4. Pre-Auth Captive-Portal Open Redirect Family

`dns_filter.cgi` and `ip_reputation_block.cgi` issue unauthenticated `302` redirects to attacker-controlled `ext_url` values. The same behavior works with the branded captive-portal host header used by the guest-access workflow.

Confirmed impact:

- pre-auth arbitrary redirect;
- branded captive-portal delivery context;
- suitable for trusted-domain abuse and captive-portal phishing pretexting.

Boundary:

- no browser JavaScript execution was promoted;
- no account takeover or OAuth callback theft was proved;
- treat both handlers as one CWE-601 family because the root cause and sink shape are near-identical.

Primary evidence:

- [open-redirect/REPORT.md](open-redirect/REPORT.md)
- [open-redirect/ARTIFACTS.md](open-redirect/ARTIFACTS.md)
- [ui_vuln_sweep_20260423af_dns_iprep_shaped](../live-summaries/ui_vuln_sweep_20260423af_dns_iprep_shaped/summary.txt)
- [ui_vuln_sweep_20260423ai_cp_brand_chain](../live-summaries/ui_vuln_sweep_20260423ai_cp_brand_chain/summary.txt)
- [ui_vuln_sweep_20260423ak_iprep_brand_sibling](../live-summaries/ui_vuln_sweep_20260423ak_iprep_brand_sibling/summary.txt)

## Candidates And Negative Results

- EPS `innerHTML` sink: static candidate only; no live attacker-controlled source was found.
- Dashboard raw ExtJS `html:` sinks: static candidate only; no writable source or execution was proved.
- `social_login.cgi` trust seam: interesting under repaired portal state, but still depends on synthetic/repaired runtime conditions.
- Upload traversal and guest/no-cookie upload variants: negative on current evidence.
- Malformed PKCS#12 content: negative for RCE or stored-XSS impact on current evidence.
- Server-side `Location: javascript:` redirect escalation: negative in Chromium testing; do not use this to inflate the open redirect.

## Reporting Rule

Report the four promoted items separately. Mention candidate chains only as follow-up research unless new live evidence changes the boundary.
