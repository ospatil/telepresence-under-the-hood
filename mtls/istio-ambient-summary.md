# Istio Ambient - Offload TLS to the Infrastructure

## The Approach

- `ztunnel` (DaemonSet, one per node) handles mTLS transparently - no sidecars, no app code changes
- Apps stay plain HTTP; `ztunnel` encrypts on the wire between nodes using HBONE protocol
- Namespace enrollment is instant - just a label, no pod restarts
- The unencrypted leg (`app ↔ ztunnel`) stays within the node boundary - same trust level as kubelet, which already has access to all pod secrets on that node
- Significantly reduces developer burden - no SSL bundles, no cert mounts, no trust configuration per service
- Best fit: most workloads where node-level trust is acceptable, teams that don't want to manage TLS in application code

## ALB Integration

- ALB can target plain HTTP pods - simpler configuration, no `backend-protocol: HTTPS` needed
- `ztunnel` handles inter-service encryption automatically
- Health checks are straightforward - same HTTP port, no cert concerns

## Telepresence Compatibility

- Works out of the box - Ambient defaults to `PERMISSIVE` mTLS, accepting both mTLS and plain HTTP
- Telepresence traffic arrives unmeshed, ztunnel accepts it without configuration changes
- No cert extraction needed for local dev - your local app just speaks plain HTTP
- Both global and header-based intercepts work seamlessly

## How It Works with AWS VPC CNI

- Istio Ambient requires the `istio-cni` DaemonSet - it configures iptables rules to redirect pod traffic through ztunnel
- It uses CNI plugin chaining: `AWS VPC CNI` (assigns ENI/IP) runs first, then `istio-cni` adds redirection rules on top
- It does NOT replace VPC CNI - it layers alongside it, making Istio Ambient CNI-agnostic
- This is also why namespace enrollment needs no pod restarts - the CNI plugin handles redirection without modifying pods

## Certificate Management

- `istiod` has a built-in CA by default - zero cert setup for basic mTLS
- For production: can swap to AWS PCA via `istio-csr` + `aws-privateca-issuer` for consistent CA infrastructure
- Cert rotation is fully managed by `istiod` - no application awareness needed

## Onboarding a New Service

- Label the namespace: `istio.io/dataplane-mode=ambient` - that's it
- No per-service certificate config, no volume mounts, no SSL bundles

## Trade-off

- Not true app-to-app encryption - there's a plain text segment within the node boundary

---

## Comparison

| | App-Managed TLS | Istio Ambient |
|---|---|---|
| Encryption boundary | App process to app process | Node to node (ztunnel) |
| App code changes | SSL bundles, cert mounts, trust config | None |
| Onboarding a new service | CSI volume + SSL config | Namespace label |
| Telepresence local dev | Lambda-issued cert from Secrets Manager | Just works (plain HTTP locally) |
| ALB config | `backend-protocol: HTTPS` | Standard HTTP backend |
| Best for | Compliance-mandated app-level TLS | Everything else |

- Both use standard AWS services (PCA, ACM, ALB) - no third-party CA infrastructure
- They coexist in the same cluster - different namespaces, different approaches, same CA if desired
- Istio Ambient is the lower-friction default for most teams; app-managed TLS is there when compliance demands it
- Developer experience is preserved in both - Telepresence keeps the inner loop fast
