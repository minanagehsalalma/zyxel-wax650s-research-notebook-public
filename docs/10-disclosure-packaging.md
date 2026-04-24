# 10 - Disclosure Packaging

The reporting strategy was to split findings aggressively and keep severity tied to what survived reproduction.

## Packaging Choices

Promoted independently:

- admin-authenticated `export-cgi` PKCS#12 command injection
- reversible `$4$` password/decryption issue
- `zysh-cgi` handler-level auth/session mismatch with bounded backend impact
- pre-auth captive-portal open redirect family

Kept as notes or candidates:

- EPS DOM-XSS
- social-login trust seam
- upload variants
- JavaScript execution via server redirect
- malformed PKCS#12 content impact

## Open Redirect Follow-Up

The open redirect disclosure was made stronger by focusing on product context:

- pre-auth reachability
- captive-portal host and redirect workflow
- request-controlled `ext_url` overriding an apparent policy URL
- realistic but benign continuation demo page

The final package stayed medium-severity and did not claim XSS or ATO.

## Cookie Parser Mismatch Follow-Up

The cookie parser mismatch was explained with exact request shapes and status differences. The important detail was not broad "auth bypass"; it was:

- `mod_auth_zyxel` accepts a request
- `zysh-cgi` sees a different unsplit value
- backend dump shows fallback behavior
- final privileged completion is still not proved

That framing is more durable than trying to inflate the issue.

## Report Artifacts

Public-safe report copies:

- [FINAL_FINDINGS_SUMMARY.md](../artifacts/reports/FINAL_FINDINGS_SUMMARY.md)
- [open redirect REPORT.md](../artifacts/reports/open-redirect/REPORT.md)
- [open redirect ARTIFACTS.md](../artifacts/reports/open-redirect/ARTIFACTS.md)

Private disclosure thread material and superseded report drafts are not included in the public-safe tree. The private archive keeps them separately for audit continuity.

