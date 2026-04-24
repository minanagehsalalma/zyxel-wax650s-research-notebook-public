# Reports Manifest

This folder contains the public-safe report subset.

## Core Reports

- [FINAL_FINDINGS_SUMMARY.md](FINAL_FINDINGS_SUMMARY.md): top-level promoted findings and boundaries.
- [Zyxel_zysh_cgi_rbac_assessment.md](Zyxel_zysh_cgi_rbac_assessment.md): bounded `zysh-cgi` authorization/session-parser analysis.
- [firmware_identification.txt](firmware_identification.txt): target firmware identity and hash context.
- [disassembly_key_offsets.txt](disassembly_key_offsets.txt): static offsets supporting the reversible password research.
- [finding2_cmdi_transcript.txt](finding2_cmdi_transcript.txt): transcript for the promoted admin-authenticated `export-cgi` command injection.

## Open Redirect Package

- [open-redirect/REPORT.md](open-redirect/REPORT.md): report-ready CWE-601 package.
- [open-redirect/POC_URLS.md](open-redirect/POC_URLS.md): reproducible URL shapes.
- [open-redirect/ARTIFACTS.md](open-redirect/ARTIFACTS.md): evidence map.
- [open-redirect/dynamic](open-redirect/dynamic/): selected text artifacts used by the open-redirect and cookie-boundary write-ups.

## Exclusions

The public snapshot does not include private PSIRT correspondence, email drafts, raw PDFs, old superseded reports, raw firmware images, extracted rootfs material, packet captures, or large runtime traces.
