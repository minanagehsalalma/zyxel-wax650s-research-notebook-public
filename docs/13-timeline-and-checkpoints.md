# 13 - Timeline And Checkpoints

This is the high-level sequence of the work. The full raw chronology lives in the copied memory, state, task board, and live summaries.

## Early Static And Lab Setup

- Firmware identified and extracted.
- Web stack mapped around `lighttpd`, `mod_auth_zyxel`, CGI handlers, `zysh-cgi`, `zysh`, and `zyshd`.
- Initial user-space rehost created with `qemu-aarch64-static` and `bubblewrap`.
- UAM socket simulation introduced to control guest/admin session type in repeatable tests.

## `zysh-cgi` Auth Boundary

- Direct CGI and web-lane tests proved guest requests can reach the real `zysh-cgi` handler.
- GDB and trace runs separated CGI-layer dispatch from backend command completion.
- Fake `/proc`, `/proc/MRD`, `clidump.conf`, switch, WLAN, and IPC gaps were progressively removed as false blockers.
- Final position: real handler-level auth/session weakness, but no finished guest-admin backend impact on the tested build.

## Admin Export Command Injection

- Sibling CGI sweeps found `export-cgi` behaved differently under admin-tagged requests.
- Semicolon-only payloads were rejected as weak evidence.
- Quote-breaking PKCS#12 password payload produced live HTTP command execution marker.
- Final position: promoted admin-authenticated command injection.

## Captive Portal Bring-Up

- Initial portal handlers returned `500`.
- Runtime XML and portal writer traces showed stale captive-profile and portal state issues.
- Post-increment refresh and `repair_portal_config.py` made `/tmp/portal_config` appear.
- `Clicktocontinue.cgi` and `social_login.cgi` moved into real backend behavior on repaired lanes.
- Final position: important runtime seam, but social login not promoted as standalone auth bypass.

## UI And Hidden Route Sweeps

- Browser and curl sweeps mapped reachable unauthenticated pages such as `/limit.html` and `/userdata.html`.
- EPS static DOM sink was found but live routes redirected away.
- Hidden helpers such as `setuser.cgi`, `nebula_ap_redirect.cgi`, and `cdr.cgi` did not produce a promoted second issue.

## Open Redirect Packaging

- `dns_filter.cgi` and `ip_reputation_block.cgi` were confirmed as pre-auth redirect sinks.
- Branded captive-portal host delivery made the finding product-specific.
- Browser JavaScript execution and ATO inflation attempts were rejected.
- Final position: one CWE-601 family affecting two sibling handlers.

## Disclosure And Notebook Packaging

- Reports were rewritten to answer vendor questions directly.
- Cookie parser mismatch details were separated from the new open redirect finding.
- The final outbound open redirect package used a realistic but benign captive-portal continuation page.
- This private notebook was created to preserve the full research story and future LLM context without publishing raw firmware or bulk lab state.

