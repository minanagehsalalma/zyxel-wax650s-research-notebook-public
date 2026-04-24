# Evidence Map

## Primary Dynamic Artifacts

- Branded sibling confirmation:
  - `artifacts/live-summaries/ui_vuln_sweep_20260423ak_iprep_brand_sibling/summary.txt`
- Direct branded-host header capture:
  - `artifacts/reports/open-redirect/dynamic/iprep_direct_brand.hdr`
- Boundary on command-sink overclaim:
  - `artifacts/reports/open-redirect/dynamic/dns_iprep_boundary_summary.txt`
- Input-shape follow-up:
  - `artifacts/reports/open-redirect/dynamic/dns_iprep_input_shape_summary.txt`

## Static Files

- Noauth handler list:
  - `runroot/usr/local/lighttpd/conf/conf.d/auth_zyxel.conf`
- Branded host rewrite:
  - `runroot/usr/local/lighttpd/conf/lighttpd.conf`
- DNS filter config model:
  - `runroot/usr/local/share/dns-filter/dns-filter.yin`
- IP reputation config model:
  - `runroot/usr/local/share/ip-reputation/ip-reputation.yin`
- Firmware and binary hashes:
  - `firmware_identification.txt`

## CVE-Context Boundary

- The package frames the two handlers as one CWE-601 family because the affected product is a captive-portal access point and the redirect is pre-authenticated.
- No private memo, email thread, or local PDF context is required to reproduce the issue.

## Packaging Boundary

- Keep this as one open redirect family.
- Keep the impact at trusted-domain abuse and phishing pretexting.
- Do not promote this package to XSS, response splitting, or account takeover without separate proof.
