# PoC URLs

These URLs are written to look like a realistic guest-network continuation flow while staying benign.

## Primary Demo URL

`http://nap-slogin.nebula.zyxel.com/cgi-bin/ip_reputation_block.cgi?host=connectivitycheck.gstatic.com&ext_url=https://guest-continue.example/portal/demo.html`

Expected behavior:

- user sees a trusted Zyxel captive-portal host
- device returns `302 Found`
- browser lands on a controlled external page that still looks like a guest-network continuation step

## What Is Actually Required

- `ext_url=` is the attacker-controlled redirect destination.
- `host=` is only a syntactically valid hostname input that gets echoed back as `threat_url=`. It does not need to belong to the attacker.
- the branded request host `nap-slogin.nebula.zyxel.com` is not required to trigger the raw redirect, but it is the most realistic and most convincing device-specific delivery shape.

## Lab Shape Versus Real-World Shape

For local lab validation, it is normal to use:

```bash
curl -H 'Host: nap-slogin.nebula.zyxel.com:8080' \
  'http://127.0.0.1:8080/cgi-bin/ip_reputation_block.cgi?host=connectivitycheck.gstatic.com&ext_url=https://guest-continue.example/portal/demo.html'
```

In a real attack scenario, the attacker would not need shell access or header spoofing. They would send the victim a normal URL under the branded captive-portal hostname and rely on the device to issue the redirect.

## Realistic Abuse Narrative

The cleanest narrative for disclosure is:

1. attacker sends the victim a Zyxel captive-portal URL that appears related to guest Wi-Fi access or network revalidation
2. the victim opens the URL and sees the trusted branded hostname first
3. the device immediately redirects to an external controlled page
4. that external page can be made to resemble a normal guest-network continuation or sign-in step

The included HTML demo intentionally stops at that visual proof and does not submit or collect credentials.

## DNS Filter Sibling

`http://nap-slogin.nebula.zyxel.com/cgi-bin/dns_filter.cgi?host=connectivitycheck.gstatic.com&ext_url=https://guest-continue.example/portal/demo.html`

## Notes

- `connectivitycheck.gstatic.com` is used here to keep the flow visually aligned with normal captive-portal behavior.
- `guest-continue.example` is intentionally benign. Replace it only with a controlled demonstration host during validation.
- Do not use this package to harvest credentials. The included HTML page is a non-collecting demonstration page only.
