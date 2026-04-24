# 00 - Story Overview

The research started as a firmware web-surface investigation and became a full lab-reconstruction exercise. The useful lesson is that the strongest results came from refusing to collapse static strings, one-off curl responses, and synthetic lab behavior into one claim. Each branch was treated as a separate hypothesis until live evidence supported it.

## Phase 1: Map The Firmware

The firmware was identified as Zyxel WAX650S `V7.10(ABRM.4)C0`, SHA-256 `e0a93db912c0b7203e0eb899f07ddef99b62a82a27352477c0f85d761576b1e0`.

The extracted rootfs showed a split web stack:

- `lighttpd` as the front door
- `mod_auth_zyxel.so` as the web auth gate
- CGI handlers under Zyxel paths
- `zysh-cgi` as the web-to-CLI bridge
- `zyshd` as the backend command daemon
- UAM sockets as the session/token authority
- captive portal helpers and temporary runtime databases

The first static result was that the shipped web stack exposed more interesting auth and CGI boundaries than a normal login page suggested.

## Phase 2: Build A Usable Lab

The lab moved from static analysis into a user-space rehost:

- rebuild a runnable `runroot`
- execute AArch64 binaries through `qemu-aarch64-static`
- isolate the rootfs with `bubblewrap`
- bring up Zyxel `lighttpd`
- emulate the UAM AF_UNIX socket responses
- seed expected runtime files, IPC, pseudo-device paths, and minimal `/proc` data

The key helper became `tools/run_zyxel_lab.sh`. The useful workflow was not a single magic boot. It was a sequence of repairs that each removed one false blocker: missing console, missing `clidump.conf`, missing `/proc/MRD`, missing UAM sockets, missing IPC, missing switch and wireless placeholders, and stale portal runtime state.

## Phase 3: Separate Auth Layers

Once the lab was stable enough to answer real questions, the auth model split into layers:

- `mod_auth_zyxel` decides whether the HTTP request passes the front door.
- `zysh-cgi` receives and parses cookie/session state again.
- `zysh` and `zyshd` decide whether the staged command actually completes.

This distinction matters. The work proved `zysh-cgi` does not strictly fail closed before command dispatch in several guest/desync shapes, but it did not prove a complete guest-to-admin backend command result on this firmware.

## Phase 4: Promote Only What Survived Live Testing

Confirmed or packaged findings:

- `export-cgi` PKCS#12 export command injection under admin-authenticated conditions.
- Zyxel reversible `$4$` password decryption using static AES parameters.
- `zysh-cgi` handler-level auth/session mismatch and cookie parser desync, bounded by incomplete backend privilege completion.
- Pre-auth open redirect family in `dns_filter.cgi` and `ip_reputation_block.cgi`.

Interesting but not promoted:

- EPS DOM-XSS sink without a live attacker-controllable source.
- `social_login.cgi` arbitrary `fb_user` acceptance under repaired/synthetic portal state.
- malformed PKCS#12 content impact attempts.
- upload traversal and upload parser variants.
- open redirect to browser JavaScript execution or ATO without a real same-origin/browser sink.

## Phase 5: Package For Review

The final packaging principle was simple: make each claim narrow enough that a reviewer can reproduce it. The open redirect became a dedicated pre-auth captive-portal finding family. The cookie parser mismatch became supporting evidence against a blanket RBAC statement, not a forced root-shell claim. The PKCS#12 command injection stayed admin-authenticated and impact-focused.

The notebook keeps both successful and failed paths because the failed paths are what make the successful claims credible.

