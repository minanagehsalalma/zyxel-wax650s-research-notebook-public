# Zyxel WAX650S Research Notebook

This public-safe wiki documents the WAX650S `V7.10(ABRM.4)C0` research arc from firmware extraction to a working live lab, then through confirmed findings, rejected chains, and disclosure packaging.

The most important result is methodological: a fragile embedded web stack was made usable enough to test real CGI behavior with static and dynamic evidence tied together. The final notebook preserves that path so another researcher, or a future LLM workflow, can resume from the known-good boundaries instead of repeating dead ends.

## Reading Order

1. [Story Overview](00-Story-Overview)
2. [Target, Firmware, And Extraction](01-Target-Firmware-And-Extraction)
3. [Emulation Bring-Up](02-Emulation-Bringup)
4. [Web Auth And Session Model](03-Web-Auth-And-Session-Model)
5. [Cookie Parser Mismatch](04-Cookie-Parser-Mismatch)
6. [PKCS#12 Export Command Injection](05-Export-Cgi-Pkcs12-Command-Injection)
7. [Reversible Password Research](06-Hardcoded-Password-Decryption)
8. [Captive Portal Runtime](07-Captive-Portal-Runtime)
9. [Captive Portal Open Redirect Family](08-Open-Redirect-Captive-Portal-Family)
10. [Negative Results And Dead Ends](09-Negative-Results-And-Dead-Ends)
11. [Disclosure Packaging](10-Disclosure-Packaging)
12. [LLM-Assisted Methodology](11-Llm-Assisted-Methodology)
13. [Artifact Map](12-Artifact-Map)
14. [Timeline And Checkpoints](13-Timeline-And-Checkpoints)
15. [Finding Matrix](14-Finding-Matrix)

## Current Promoted Findings

- Admin-authenticated command injection in `export-cgi` PKCS#12 export handling.
- Reversible Zyxel `$4$` password storage/decryption issue.
- `zysh-cgi` handler-level authorization/session parsing weakness, with a proven CGI-layer split but no final guest-admin task completion on this build.
- Pre-auth captive-portal open redirect family in `dns_filter.cgi` and `ip_reputation_block.cgi`.

## Important Boundaries

- Do not claim completed guest-to-root compromise from the current `zysh-cgi` evidence.
- Do not claim `javascript:` execution from the server-side open redirect; the confirmed issue is raw HTTP `Location` control.
- Do not promote the EPS DOM-XSS or social-login seam without a non-synthetic live source.
- Treat the emulation lab as a strong behavior microscope, not as a full-device oracle.
- Keep private disclosure correspondence and superseded draft reports out of public releases.
