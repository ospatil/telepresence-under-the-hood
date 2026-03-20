# Design Note: PCA Hierarchy - Root + Subordinate CAs

## Overview

The demo uses a three-tier AWS PCA hierarchy instead of a single root CA. This separates cluster service cert issuance from developer cert issuance while maintaining mutual trust through a shared root.

## Architecture (Implemented)

```
AWS PCA Root CA (e2e-tls-demo-root-ca)
  │
  ├── Subordinate CA: e2e-tls-demo-cluster-ca
  │     └── issues certs to pods via cert-manager CSI driver
  │
  └── Subordinate CA: e2e-tls-demo-dev-ca
        └── issues dev certs via Lambda → Secrets Manager
```

## Trust Model

- All services trust the root CA cert in their truststore (`ca.crt` = root CA public cert)
- Certs issued by either subordinate chain back to the root, so mutual trust is automatic
- Pod certs (cluster CA) and dev certs (dev CA) are both trusted by all parties

## Why a Hierarchy

- **Revocation isolation**: disable the dev CA without affecting cluster services
- **Least privilege**: cert-manager only has access to the cluster CA; Lambda only has access to the dev CA; developers only need Secrets Manager access
- **Audit**: distinguish cluster-issued vs developer-issued certs by looking at the issuer field
- **Security boundary**: the dev CA cannot issue CA certificates (PathLen0 constraint)

## Implementation Details

- Root CA: 10-year validity, `ROOT` type, only signs subordinate CAs
- Subordinate CAs: 5-year validity, `SUBORDINATE` type, `PathLen0` (cannot create further sub-CAs)
- Template: `SubordinateCACertificate_PathLen0/V1`
- All CAs use ECDSA P-256 (`EC_prime256v1`)

## Cost

- 3 PCAs at ~$400/month each = ~$1,200/month
- Per-cert cost: ~$0.75 each (general purpose mode)
