# 05 - `export-cgi` PKCS#12 Command Injection

## Claim

The admin-authenticated PKCS#12 export path in `export-cgi` concatenates user-controlled export password data into a shell command in a quote-breakable way, producing command execution in the CGI context.

## Root Cause Shape

The vulnerable path is the PKCS#12 export builder. The important condition is not just "export-cgi exists"; it is the specific text-field path that places attacker-controlled password material into command construction.

The corrected payload shape was quote-breaking, not semicolon-only. Earlier semicolon-only retries were low signal and should not be used to downgrade the later proof.

## Dynamic Proof

The live HTTP proof used an admin-tagged request to the config export path and then a corrected PKCS#12 password payload.

The decisive observation:

- the request returned `HTTP 200`
- the response body echoed the marker
- the body began with a UID line in the extracted lab

The UID observed in the lab reflected the local extracted-workspace execution context. On hardware, impact should be described as CGI command execution in the product's service context, not as a host-UID artifact.

## Evidence Files

- [artifacts/live-summaries/admin_web_handler_focus_20260422a/summary.txt](../artifacts/live-summaries/admin_web_handler_focus_20260422a/summary.txt)
- [artifacts/live-summaries/admin_cert_export_probe_20260422a/summary.txt](../artifacts/live-summaries/admin_cert_export_probe_20260422a/summary.txt)
- [artifacts/reports/FINAL_FINDINGS_SUMMARY.md](../artifacts/reports/FINAL_FINDINGS_SUMMARY.md)
- [artifacts/reports/finding2_cmdi_transcript.txt](../artifacts/reports/finding2_cmdi_transcript.txt)

## Boundary

This is not pre-auth. It requires an admin-authenticated lane or equivalent admin handler reachability.

The sibling certificate-export branch did not reproduce the same issue:

- plain local cert export returned `HTTP 500` in that run
- quote-breaking variants were rejected at `HTTP 400`
- no marker was produced

The PKCS#12 password export path remains the clear promoted sink.
