# 06 - Reversible Password Research

## Claim

Zyxel `$4$` password material can be decrypted using static cryptographic parameters recovered from the firmware, exposing plaintext configuration credentials where the encrypted form is available.

## Research Path

This branch came from static and cryptographic analysis rather than the live web lab. The key work was:

- identify Zyxel scheme IDs
- recover the AES parameters from shipped binaries
- validate decrypted plaintext against known or recovered config material
- separate credential recovery from any unrelated web auth claim

The public companion project in the same GitHub account covers the decryptor tooling separately. This notebook records how the finding fit into the WAX650S research arc.

## Impact

The confirmed impact is credential disclosure from encrypted configuration material. It is not automatically a remote login bypass unless an attacker can obtain the relevant encrypted config or backup.

This finding is strongest when chained with:

- exposed config backup download
- admin export weakness
- filesystem or backup disclosure

It should not be inflated into zero-auth takeover by itself.

## Evidence Files

- [artifacts/reports/FINAL_FINDINGS_SUMMARY.md](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/FINAL_FINDINGS_SUMMARY.md)
- [artifacts/reports/disassembly_key_offsets.txt](https://github.com/minanagehsalalma/zyxel-wax650s-research-notebook-public/blob/main/artifacts/reports/disassembly_key_offsets.txt)
