# Development certificate

This directory contains a deliberately public self-signed certificate pair for
the reserved hostname `s-ui-installer.invalid`.

It is included only so packaging, certificate validation, and offline smoke
tests have real PEM files. The private key is public and provides no security.
The installer refuses to use it unless both conditions are explicitly set:

```bash
ALLOW_BUNDLED_EXAMPLE_CERT=1 ./install.sh \
  --cert-mode example \
  --skip-cert-host-check
```

Never replace these files with a production certificate or key. Put real files
on the target server and pass `--cert` plus `--key`, or place them under the
ignored `certs/live/` directory for a private deployment bundle.
