# Public Release Checklist

Use this before making the public snapshot visible.

## Required

- Confirm coordinated disclosure timing allows publication.
- Confirm no private PSIRT correspondence, email drafts, or raw vendor replies are present.
- Confirm no raw firmware, rootfs, `runroot`, `.lab-state`, packet captures, or bulk traces are present.
- Confirm no local workstation paths, access tokens, GitHub tokens, or generated session tokens are present.
- Confirm all GitHub links point to the public repository name.
- Confirm all markdown links pass local validation.
- Confirm the finding boundaries still match the latest vendor/fix state.

## Optional

- Add CVE IDs after assignment.
- Add firmware-fixed version references after vendor release.
- Add a short publication note explaining what changed from private disclosure to public archive.
