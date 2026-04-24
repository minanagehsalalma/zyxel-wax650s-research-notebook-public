# 01 - Target, Firmware, And Extraction

## Target Identity

- Vendor: Zyxel
- Device: WAX650S
- Firmware: `V7.10(ABRM.4)C0`
- Firmware SHA-256: `e0a93db912c0b7203e0eb899f07ddef99b62a82a27352477c0f85d761576b1e0`
- Primary userland architecture: AArch64

The firmware identification evidence is preserved in [artifacts/reports/firmware_identification.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/firmware_identification.txt).

## Initial Surface Map

The relevant management surface was not one monolithic web app. It was a layered stack:

- `lighttpd` configuration and host/path routing
- `mod_auth_zyxel.so` authentication gate
- CGI binaries for admin, portal, filtering, upload, and export behavior
- `zysh-cgi` as the web command bridge
- `zysh` and `zyshd` as the CLI/backend pair
- UAM socket infrastructure for session lookup
- captive portal runtime databases and temporary files

The extracted frontend also contained ExtJS pages, login helpers, EPS legacy pages, captive portal wrappers, and dashboard rendering code. Static UI sinks were tracked, but they were not promoted without live source control.

## Step-By-Step Extraction And Normalization

The earlier version of this chapter was too compressed. The useful part of this notebook was not just "we had a rootfs"; it was how the firmware blob turned into a runnable research tree.

### 1. Validate The Firmware Blob

Start from the vendor image kept in the workspace root:

```bash
cd /path/to/Zyxel
sha256sum 710ABRM4C0.bin
```

Expected hash:

```text
e0a93db912c0b7203e0eb899f07ddef99b62a82a27352477c0f85d761576b1e0  710ABRM4C0.bin
```

This matters because later routing, handler names, and CGI behavior are all build-specific.

### 2. Confirm The Extracted Firmware Bundle

The workspace preserves the extraction result as `710ABRM4C0_extracted/`. The bundle metadata records that the original image was unpacked into 43 FIT images plus a standalone config file:

```bash
sed -n '1,6p' 710ABRM4C0_extracted/README.txt
python3 -m json.tool 710ABRM4C0_extracted/manifest.json | sed -n '1,40p'
```

The important extracted components are:

- `710ABRM4C0_extracted/bin_images/`
- `710ABRM4C0_extracted/rootfs/`
- `710ABRM4C0_extracted/710ABRM4C0.conf`
- `710ABRM4C0_extracted/manifest.json`

The exact one-shot unpack command that originally produced this bundle was not preserved in the workspace. That gap is now closed by a reconstructed workflow that was re-verified against the real firmware blob on 2026-04-24.

### 2A. Verified Extraction Command Chain

Install the host-side tools first:

```bash
sudo apt-get update
sudo apt-get install -y u-boot-tools squashfs-tools
python3 -m pip install --user ubi-reader
```

Then run the exact verified extractor:

```bash
tools-reference/extract_710ABRM4C0.sh \
  710ABRM4C0.bin \
  /tmp/710ABRM4C0_verified_extract \
  710ABRM4C0_extracted/710ABRM4C0.conf
```

That script was added to this notebook and does the exact chain that was verified locally:

1. enumerate FIT nodes with `fdtget -l 710ABRM4C0.bin /images`
2. extract each FIT payload with `dumpimage -T flat_dt -p <index> -o ...`
3. copy the preserved standalone config file `710ABRM4C0_extracted/710ABRM4C0.conf`
4. unpack the root UBI container with `ubireader_extract_images`
5. extract the real root filesystem with `unsquashfs`

The rootfs step is important because the file named `img-695833001_vol-ubi_rootfs.ubifs` is not UBIFS on this build. It is a SquashFS filesystem with a misleading suffix, and that is why the working chain uses `unsquashfs` instead of `ubireader_extract_files`.

One subtlety also explains the "43 FIT images" wording in `README.txt` versus the 42 files visible under `bin_images/`: the FIT contains two entries whose description is `ff.bin`, so a description-based extraction loop overwrites one with the other. The preserved extracted tree in this workspace has the same collision.

### 3. Inspect The Extracted Tree

The first useful check is simply to verify the split between firmware components and the Linux rootfs:

```bash
find 710ABRM4C0_extracted -maxdepth 2 -type d | sort
find 710ABRM4C0_extracted/bin_images -maxdepth 1 -type f | sort | sed -n '1,20p'
```

The important findings at this stage were:

- `bin_images/openwrt-ipq-ipq807x_64-ubi-root.img` contains the main root filesystem payload.
- `bin_images/mrd-WAX650S.bin` is needed later because the lab helpers seed `/proc/MRD` from it.
- `710ABRM4C0.conf` exposes the standalone configuration with the WLAN, management, and HTTP defaults.
- `rootfs/` already contains the web stack and Zyxel binaries that matter for static triage.

### 4. Notice Why The Raw Rootfs Is Not Runnable

The extracted `rootfs/` is not a clean, directly runnable filesystem. Several entries that should be symlinks are stored as tiny placeholder files:

```bash
ls -lh 710ABRM4C0_extracted/rootfs/bin \
       710ABRM4C0_extracted/rootfs/lib \
       710ABRM4C0_extracted/rootfs/lib64 \
       710ABRM4C0_extracted/rootfs/sbin \
       710ABRM4C0_extracted/rootfs/etc_writable
```

Those placeholders are one reason the project needed a normalization step. Static analysis can read through them, but `qemu-aarch64-static` and `lighttpd` cannot run correctly until those links and runtime paths are repaired.

### 5. Build A Runnable `runroot`

The canonical rebuild step is:

```bash
tools/run_zyxel_lab.sh rebuild --phase core
```

Under the hood this rebuilds `runroot/` from `710ABRM4C0_extracted/rootfs/` with [prepare_zyxel_runroot.py](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/tools-reference/prepare_zyxel_runroot.py). The normalization script does the parts that matter for a researchable filesystem:

- converts the known placeholder files into real symlinks
- creates the runtime directories the firmware expects
- seeds required stub files under `dev`, `proc`, `sys`, and `var`
- installs a lab `lighttpd.conf` that binds to `127.0.0.1:8080`
- copies the host `qemu-aarch64-static` binary into the guest tree
- seeds the lab admin passwd/shadow state

That rebuild step is where the extracted firmware stops being a static object and becomes a candidate lab filesystem.

### 6. Verify The First Healthy Core Lane

Once `runroot/` exists, verify that the core lab actually came up:

```bash
tools/run_zyxel_lab.sh health --phase core
tools/run_zyxel_lab.sh status
```

The current known-good checkpoint described in the notebook is:

- clean stop
- `tools/run_zyxel_lab.sh rebuild --phase core`
- `tools/run_zyxel_lab.sh health --phase core`

The expected success condition is not just "a process exists." The useful proof is that the lane reaches the Zyxel CLI side cleanly enough to answer `show running-config` and exposes the `Router(config)#` state noted in the artifact summaries.

### 7. Why Extraction Became A Bring-Up Problem

At this point the project had already crossed the real boundary:

- extraction identified the files
- normalization repaired the filesystem semantics
- `bubblewrap` and `qemu-aarch64-static` made the AArch64 userland callable
- synthetic UAM sockets and runtime seeding made the web stack analyzable

That is why the rest of the notebook talks about "lab bring-up" instead of treating firmware extraction as a one-command prelude. On this target, extraction and runtime repair were part of the same problem.

## Why Extraction Alone Was Not Enough

Static analysis quickly showed suspicious strings and routes, but the strongest questions depended on runtime behavior:

- Does `mod_auth_zyxel` actually let a request through?
- What session type does the CGI believe it received?
- Does `zysh-cgi` stage a command before or after privilege checks?
- Does `zyshd` consume the request and return output?
- Are captive portal handlers dead, state-gated, or reachable after runtime repair?

That forced the project into rehosting and emulation instead of a pure strings report.

## Key Static Evidence

Static artifacts kept in this repo include:

- report-level firmware identity and binary offsets
- `auth_zyxel.conf` and web routing references inside report artifacts
- YANG/config model excerpts for DNS filter and IP reputation block page behavior
- disassembly and string evidence for `zysh-cgi`, `export-cgi`, and redirect handlers

The source notes under [artifacts/reports](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/MANIFEST.md) are a public-safe subset of the working reports. Private correspondence, superseded drafts, raw firmware, and extracted rootfs material are intentionally excluded.
