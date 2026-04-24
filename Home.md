# Zyxel WAX650S Research Notebook

This public-safe wiki documents the WAX650S `V7.10(ABRM.4)C0` research arc from firmware extraction to a working live lab, then through confirmed findings, rejected chains, and disclosure packaging.

The most important result is methodological: a fragile embedded web stack was made usable enough to test real CGI behavior with static and dynamic evidence tied together. The final notebook preserves that path so another researcher, or a future LLM workflow, can resume from the known-good boundaries instead of repeating dead ends.

## Reading Order

1. [Story Overview](docs/00-story-overview.md)
2. [Target, Firmware, And Extraction](docs/01-target-firmware-and-extraction.md)
3. [Emulation Bring-Up](docs/02-emulation-bringup.md)
4. [Web Auth And Session Model](docs/03-web-auth-and-session-model.md)
5. [Cookie Parser Mismatch](docs/04-cookie-parser-mismatch.md)
6. [PKCS#12 Export Command Injection](docs/05-export-cgi-pkcs12-command-injection.md)
7. [Reversible Password Research](docs/06-hardcoded-password-decryption.md)
8. [Captive Portal Runtime](docs/07-captive-portal-runtime.md)
9. [Captive Portal Open Redirect Family](docs/08-open-redirect-captive-portal-family.md)
10. [Negative Results And Dead Ends](docs/09-negative-results-and-dead-ends.md)
11. [Disclosure Packaging](docs/10-disclosure-packaging.md)
12. [LLM-Assisted Methodology](docs/11-llm-assisted-methodology.md)
13. [Artifact Map](docs/12-artifact-map.md)
14. [Timeline And Checkpoints](docs/13-timeline-and-checkpoints.md)
15. [Finding Matrix](docs/14-finding-matrix.md)

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
