# Certificates

This directory holds TLS certificates used by the app proxy at runtime.

**Do NOT commit `.pem` files to the repository.**  
The private key (`privkey.pem`) and certificate chain (`fullchain.pem`) are secrets and must never be tracked in git.

## How certificates are managed

- **Automated renewal:** `.github/workflows/renew-cert.yml` runs monthly and renews the Let's Encrypt certificate for `config.riftmate.lol`.
- **Local builds:** place `fullchain.pem` and `privkey.pem` here before building.
- **CI builds:** the release workflows expect these files to be present (generated or supplied as secrets).

If you need to rotate the certificate manually, revoke the old one via Let's Encrypt before generating a new keypair.
