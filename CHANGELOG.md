# Changelog

## 1.1.1

- Stop immediately when an existing installation is detected without `--upgrade`.
- Validate domain syntax as soon as it is entered.
- Require the domain A/AAAA records to match the VPS public IP by default.
- Add `--expected-ip` for multi-address/NAT deployments and
  `--skip-domain-ip-check` for deliberate CDN or reverse-proxy setups.
- Validate explicit certificate/key paths, PEM format, pairing, hostname, and
  expiry during interactive input.
- Reject expired certificates and encrypted/unattended private keys.

## 1.1.0

- Add `cert-status` to show configured source and installed certificate paths.
- Add `cert-auto` to rediscover Certbot, acme.sh, domain-named, and `/root` certificates.
- Add `cert-set CERT KEY` and optional certificate arguments to `cert-sync`.
- Validate certificate/key matching, hostname, expiry, and actual TLS loading.
- Back up the active certificate and automatically roll back failed reloads.
- Make unchanged `cert-sync` output show the source paths instead of a bare status message.

## 1.0.0

- Initial cross-distribution S-UI Docker installer.
- Automatic China/global network profiling and mirror selection.
- Dynamic latest S-UI release resolution with verified fallback snapshot.
- Certificate discovery, validation, self-signed fallback, and scheduled sync.
- Existing-database migration, online backups, restore, update, and doctor tools.
- UFW/firewalld, BBR, IPv4/IPv6 forwarding, and protocol-port validation.
- GitHub Actions ShellCheck, smoke tests, and sensitive-file guard.
