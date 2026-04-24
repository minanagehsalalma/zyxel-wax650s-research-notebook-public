# 14 - Finding Matrix

| Area | Status | Confirmed Impact | Boundary |
| --- | --- | --- | --- |
| `export-cgi` PKCS#12 export | Promoted | Admin-authenticated command injection in CGI context | Not pre-auth; lab UID is not hardware UID |
| Zyxel `$4$` password decryption | Promoted | Plaintext recovery from encrypted config material | Requires access to encrypted material |
| `zysh-cgi` cookie/session mismatch | Bounded finding | CGI-layer parser mismatch and command staging despite weak session handling | No completed guest admin command output proved |
| `dns_filter.cgi` open redirect | Promoted family | Pre-auth arbitrary `Location` redirect | No browser JS execution or ATO proved |
| `ip_reputation_block.cgi` open redirect | Promoted family | Same pre-auth redirect class as DNS filter handler | Best reported together with `dns_filter.cgi` |
| `fbwifi_continue.cgi` redirect | Weaker supporting note | Cookie-derived redirect behavior | Less central and less clean than primary handlers |
| `social_login.cgi` `fb_user` acceptance | Candidate only | Repaired portal lane can reach backend acceptance | Depends on synthetic/repaired portal state |
| EPS `innerHTML` sink | Static candidate only | Real unsafe sink in legacy EPS flow | No live attacker-controllable source found |
| Upload traversal/parser variants | Negative | No guest/no-cookie file effect | Do not reopen without new static sink |
| Malformed PKCS#12 content | Negative | No promoted content-parser impact | Real issue is export command construction |
| Dashboard raw `html:` sinks | Candidate only | Backend values rendered into raw ExtJS HTML in static code | No writable source or live execution proved |
| Hidden top-level helpers | Negative or informational | Some self-service/logout behavior mapped | No admin crossover or side effect proved |

## Reporting Rule

Use the status column exactly when writing future reports. Do not merge candidates into promoted findings unless new live evidence changes the boundary.

