# `zysh-cgi` RBAC Assessment

Date: 2026-04-21

## Bottom Line

The current evidence supports a bounded `zysh-cgi` authorization/session-parser finding, not a completed guest administrative takeover.

The important result is narrower and still useful:

- `mod_auth_zyxel` and `zysh-cgi` parse accepted cookie input differently;
- a guest-authenticated request can reach the real `zysh-cgi` handler;
- malformed-but-accepted cookie strings can drive `zysh-cgi` into its missing-user fallback path;
- the fallback changes the staged CLI prelude, but final privileged command output was not reproduced from a guest web session.

## Static Evidence

The relevant `zysh-cgi` control-flow points are preserved in [disassembly_key_offsets.txt](disassembly_key_offsets.txt):

- `0x401780`: `uam_find_first_match`
- `0x40178c`: load user type byte
- `0x401838`: `fork()`
- `0x401d50`: `execve()`

Useful strings from the same binary include:

- `user type: %d`
- `var data_ready = %d;`
- `var usr_type = %d;`
- `configure terminal exit|%s %d`
- `/bin/zysh`
- `can't found user: addr = %s, unique = %s: set to type admin`

This is enough to reject a broad claim that `zysh-cgi` itself strictly denies guest sessions before command dispatch.

## Dynamic Evidence

The strongest public-safe dynamic artifacts are:

- [manual_cookie_desync_smoke_20260421b](../live-summaries/manual_cookie_desync_smoke_20260421b/summary.txt)
- [cookie_desync_backend_compare_20260422e](../live-summaries/cookie_desync_backend_compare_20260422e/summary.txt)
- [manual_cookie_desync_summary.txt](open-redirect/dynamic/manual_cookie_desync_summary.txt)
- [dup_valid_first.zysh-cgi.dump.txt](open-redirect/dynamic/dup_valid_first.zysh-cgi.dump.txt)

The live cookie-desync proof preserves these facts:

- baseline `Cookie: authtok=testtoken` returns `HTTP 200` and logs `user type: 1`;
- `Cookie: authtok=testtoken; foo=bar` is still accepted by the web layer, but the CGI-side dump records the unsplit unique value;
- `Cookie: authtok=testtoken; authtok=junk` reaches the same parser mismatch shape;
- the desync variants change the staged CLI prelude from the baseline `enable` path into a path containing `configure terminal`;
- both desync variants still stop short of a clean privileged response body and time out with no proved administrative command result.

## Current Impact

Confirmed:

- handler-level cookie/session parser mismatch;
- real `lighttpd` to `zysh-cgi` reachability;
- admin-type fallback text is live-reachable in the CGI-side dump;
- CLI staging changes under desync input.

Not confirmed:

- guest-origin configuration dump;
- guest-origin administrative command completion;
- no-cookie exploitation;
- root shell or full device takeover.

## Recommended Framing

Report this as a bounded authorization/session parsing flaw in `zysh-cgi`.

Do not merge it with the `export-cgi` command injection or the captive-portal open redirect. Those are separate bug classes with separate privilege boundaries.
