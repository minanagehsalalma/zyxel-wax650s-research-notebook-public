# 02 - Emulation Bring-Up

The most important engineering work was turning a static rootfs into a repeatable web lab. The lab did not become a perfect full-device emulation. It became a strong enough behavior microscope to test real Zyxel binaries, real CGI paths, and real web auth boundaries.

## Starting Point

The rootfs could be inspected, but stock full-system boot paths were not immediately clean. The GPL kernel configuration made a generic `qemu-system-aarch64 -M virt` path unattractive because the expected serial and virtio devices did not line up cleanly. The practical route was a user-space rehost first.

The current reference helper is [tools-reference/run_zyxel_lab.sh](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/tools-reference/run_zyxel_lab.sh).

## Core Lab Shape

The lab used:

- `qemu-aarch64-static` to execute AArch64 vendor binaries
- `bubblewrap` to bind the prepared rootfs as `/`
- Zyxel `lighttpd` as the real HTTP listener
- Zyxel CGI binaries in their native paths
- `zyshd_wd` and related backend pieces where possible
- synthetic UAM AF_UNIX responders for controlled session lookup
- seeded runtime files and pseudo-devices to remove false startup blockers

The best known operational cycle was:

```bash
tools/run_zyxel_lab.sh stop
tools/run_zyxel_lab.sh rebuild --phase core
tools/run_zyxel_lab.sh health --phase core
```

The goal of this cycle was not to pretend the lab was stock hardware. It was to create a clean, repeatable lane where each missing runtime assumption could be isolated.

## False Blockers Removed

The lab helper evolved to seed or bind:

- `/var/zyxel/clidump.conf`
- `/dev/CP_dev`
- `/dev/switch0`
- WLAN placeholder config
- station-list directories
- `/proc/MRD`
- OpenRC softlevel state
- `/dev/console`
- UAM sockets: `/dev/user-request`, `/dev/user-request2`, `/dev/user-notify`
- known IPC keys needed by Zyxel runtime components
- a no-op `/tmp/link-updown-socket`

Each repair was added because a live trace showed a vendor binary was blocked on that exact missing assumption.

## Core Versus Full Phase

The lab used a staged model:

- `core`: bring up enough backend and web stack to test admin/guest auth and CGI behavior.
- `full` or `promote-full`: add portal and web-lane transitions after core health was known.

This reduced noise. Portal testing was not allowed to invalidate the core `zysh-cgi` or `export-cgi` evidence unless it ran on the same healthy lane.

## Portal Runtime Repair

Captive portal handlers depended on runtime state that was not generated cleanly by default. The decisive state included:

- `/tmp/portal_config`
- `portal_info`
- `whybrid`
- captive profile runtime XML reference state

The key helpers were:

- [tools-reference/prepare_portal_runtime.py](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/tools-reference/prepare_portal_runtime.py)
- [tools-reference/repair_portal_config.py](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/tools-reference/repair_portal_config.py)
- [tools-reference/force_portal_post_increment_refresh.sh](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/tools-reference/force_portal_post_increment_refresh.sh)

The strongest portal conclusion was not that every portal login was product-auth bypass. It was that the lab could move the handlers from dead `500` responses into real backend behavior and then identify which pieces were synthetic.

## What The Lab Can Prove

The lab can prove:

- real shipped binaries execute the request path
- `mod_auth_zyxel` and CGI parsers disagree in specific cookie shapes
- `zysh-cgi` stages commands and reaches backend paths before final body completion
- admin `export-cgi` PKCS#12 password handling reaches command execution
- captive portal redirect handlers issue real pre-auth `302` responses

The lab cannot by itself prove:

- final full-system guest root shell
- stock browser-valid admin login from a guessed password
- social-login auth bypass without a non-synthetic portal runtime source
- browser JavaScript execution from a server-side redirect

That distinction is the main reason the findings stayed reviewable.
