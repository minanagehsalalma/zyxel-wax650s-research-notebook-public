# 12 - Artifact Map

## Curated Live Summaries

The public snapshot keeps only the canonical live artifacts that are referenced by the chapters:

- [artifacts/live-summaries/INDEX.md](../artifacts/live-summaries/INDEX.md)

Large traces, raw logs, private lab state, and exploratory dead-end runs are intentionally excluded.

## Reports

Public-safe reports and evidence notes:

- [artifacts/reports/FINAL_FINDINGS_SUMMARY.md](../artifacts/reports/FINAL_FINDINGS_SUMMARY.md)
- [artifacts/reports/Zyxel_zysh_cgi_rbac_assessment.md](../artifacts/reports/Zyxel_zysh_cgi_rbac_assessment.md)
- [artifacts/reports/firmware_identification.txt](../artifacts/reports/firmware_identification.txt)
- [artifacts/reports/disassembly_key_offsets.txt](../artifacts/reports/disassembly_key_offsets.txt)

Open redirect disclosure package:

- [artifacts/reports/open-redirect/REPORT.md](../artifacts/reports/open-redirect/REPORT.md)
- [artifacts/open-redirect-poc](../artifacts/open-redirect-poc/)

## Tool References

Selected helper scripts are under:

- [tools-reference](../tools-reference/)

These are included to explain how the lab worked. They are not a turnkey firmware distribution because raw firmware and rootfs material are excluded.

## Exclusions

Not included:

- firmware binaries
- extracted rootfs
- `runroot`
- `.lab-state`
- large traces and logs
- packet captures
- transient PID/process state
- raw local workspace paths
- private PSIRT correspondence
- superseded report drafts that overstate current impact
