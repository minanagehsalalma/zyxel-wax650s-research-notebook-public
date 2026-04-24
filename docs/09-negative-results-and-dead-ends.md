# 09 - Negative Results And Dead Ends

This project kept negative results because they prevent repeated bad escalation attempts.

## Open Redirect Escalation Attempts

Rejected:

- promoting server-side `Location: javascript:` to browser XSS
- claiming ATO without a product-real OAuth or same-origin browser sink
- CRLF response splitting from percent-encoded payloads

Result:

- raw HTTP `Location` control is real
- browser execution was not proved
- strongest honest framing is pre-auth captive-portal redirect abuse

## EPS DOM-XSS Candidate

Static sink:

- `access_eps.html` writes `errMsg` into `innerHTML`
- `dummy_eps.html` can feed `eps_failure(messages)`

Live boundary:

- direct EPS pages redirected back to `/`
- direct backend EPS endpoints were not reachable on the tested listener
- no attacker-controllable live source was found

Result: static candidate only.

## Social Login Candidate

Interesting behavior:

- `userdata.html` submits only `fb_user`
- repaired portal state could produce backend acceptance

Rejected as standalone finding because:

- strongest acceptance depended on repaired/synthetic portal runtime
- header-level browser-valid cookie issuance stayed ambiguous
- stable stock precondition was not isolated

## Malformed PKCS#12 Content

The meaningful PKCS#12 impact was in the export command construction path, not in malformed P12 file content. Attempts to turn malformed content into stronger impact did not produce a promoted result.

## Upload And Sibling CGI Probes

`file_upload-cgi` and sibling handler permutations were tested with guest, no-cookie, admin, duplicate-cookie, and semicolon variants.

Result:

- guest/no-cookie upload paths did not produce a file effect
- sibling handlers did not improve over the `zysh-cgi` parser mismatch
- no second upload finding was promoted

## Hidden UI Routes

Directly reachable pages such as `/limit.html` and `/userdata.html` were mapped. They are useful surface documentation but not promoted vulnerabilities by themselves.

## Guiding Rule

If the branch needs a second unproved bug to become high impact, keep it as chaining potential, not as the primary claim.

