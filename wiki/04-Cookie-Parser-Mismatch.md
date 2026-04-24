# 04 - Cookie Parser Mismatch

## Claim

`mod_auth_zyxel` and `zysh-cgi` parse cookie/session state differently. A request can pass the front auth layer while `zysh-cgi` receives an unsplit cookie suffix and enters a missing-user fallback path.

## Why It Matters

Zyxel's broad position was that `zysh-cgi` was protected by session-type verification. The live evidence is narrower and more precise:

- the HTTP request can reach the real `zysh-cgi` handler
- `zysh-cgi` can stage commands after a parser mismatch
- the handler logs show fallback behavior such as missing user and admin type assignment
- final privileged command completion is still not proven on this build

This is not packaged as a clean guest root-shell bug. It is packaged as a real handler-level auth/session mismatch that weakens the claimed RBAC boundary.

## Live Request Shapes

The important cookie-order observations:

- `Cookie: authtok=VALID; foo=bar`
  - `export-cgi`: `HTTP 400`
  - `zysh-cgi`: `HTTP 200`
- `Cookie: authtok=VALID; authtok=junk`
  - `export-cgi`: `HTTP 400`
  - `zysh-cgi`: `HTTP 200`
- `Cookie: authtok=junk; authtok=VALID`
  - both paths: `HTTP 302`

The backend dump captured the unsplit suffix reaching the user key:

```text
unique = testtoken; foo=bar
set to type admin
```

## Evidence Files

Relevant curated artifacts:

- [manual_cookie_desync_summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/open-redirect/dynamic/manual_cookie_desync_summary.txt)
- [dup_valid_first.zysh-cgi.dump.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/open-redirect/dynamic/dup_valid_first.zysh-cgi.dump.txt)
- [artifacts/live-summaries/manual_cookie_desync_smoke_20260421b/summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/manual_cookie_desync_smoke_20260421b/summary.txt)
- [artifacts/live-summaries/cookie_desync_backend_compare_20260422e/summary.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/live-summaries/cookie_desync_backend_compare_20260422e/summary.txt)
- [artifacts/reports/Zyxel_zysh_cgi_rbac_assessment.md](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/Zyxel_zysh_cgi_rbac_assessment.md)

## Boundary

The mismatch is real. The backend privilege impact remains bounded:

- baseline guest behavior logs `user type: 1`
- semicolon suffix variants trigger missing-user fallback and staging differences
- both still end as `HTTP 200` plus timeout or zero body in the strongest same-run compare
- no finished config dump or root shell was proved from a guest web cookie

That boundary should stay intact in any future report.
