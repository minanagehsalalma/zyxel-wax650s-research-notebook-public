# Zyxel WAX650S Research Notebook

Public-safe research notebook for Zyxel WAX650S firmware `V7.10(ABRM.4)C0`.

This repo is written as a story-format wiki for researchers and future LLM-assisted follow-up work. It captures how the lab was brought up, which findings were confirmed, which chains failed, and where the evidence boundaries sit.

## Target

- Device: Zyxel WAX650S
- Firmware: `V7.10(ABRM.4)C0`
- Firmware SHA-256: `e0a93db912c0b7203e0eb899f07ddef99b62a82a27352477c0f85d761576b1e0`
- Architecture: AArch64 userland
- Main web stack: Zyxel `lighttpd`, `mod_auth_zyxel.so`, CGI handlers, `zyshd`, UAM sockets

## How To Read This

Start with [Home](Home.md), then read the numbered chapters under [docs](docs/). The notebook intentionally separates:

- confirmed findings from candidates
- static evidence from dynamic evidence
- synthetic lab state from device-faithful runtime behavior
- exploitability from useful defensive research boundaries

## Contents

- [Story Overview](docs/00-story-overview.md)
- [Target, Firmware, And Extraction](docs/01-target-firmware-and-extraction.md)
- [Emulation Bring-Up](docs/02-emulation-bringup.md)
- [Web Auth And Session Model](docs/03-web-auth-and-session-model.md)
- [Cookie Parser Mismatch](docs/04-cookie-parser-mismatch.md)
- [PKCS#12 Export Command Injection](docs/05-export-cgi-pkcs12-command-injection.md)
- [Reversible Password Research](docs/06-hardcoded-password-decryption.md)
- [Captive Portal Runtime](docs/07-captive-portal-runtime.md)
- [Captive Portal Open Redirect Family](docs/08-open-redirect-captive-portal-family.md)
- [Negative Results And Dead Ends](docs/09-negative-results-and-dead-ends.md)
- [Disclosure Packaging](docs/10-disclosure-packaging.md)
- [LLM-Assisted Methodology](docs/11-llm-assisted-methodology.md)
- [Artifact Map](docs/12-artifact-map.md)
- [Timeline And Checkpoints](docs/13-timeline-and-checkpoints.md)
- [Finding Matrix](docs/14-finding-matrix.md)

## What Is Not In This Repo

This repo deliberately excludes raw firmware images, extracted rootfs trees, `runroot`, large traces, live process state, private disclosure correspondence, and bulk logs. The goal is a durable research reference, not a forensic dump.

Curated evidence is under [artifacts](artifacts/). Selected helper scripts are under [tools-reference](tools-reference/).

## Public Release Status

This tree is prepared as a clean-history public snapshot. It should be published only after the relevant coordinated disclosure window allows release. The full private research archive is intentionally separate.
