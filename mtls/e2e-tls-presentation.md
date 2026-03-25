---
marp: true
theme: default
paginate: true
backgroundColor: #fff
style: |
  section {
    font-size: 22px;
  }
  h1 {
    color: #232f3e;
  }
  h2 {
    color: #c7511f;
  }
  h3 {
    color: #232f3e;
  }
  table {
    font-size: 18px;
  }
  code {
    font-size: 16px;
  }
  pre {
    font-size: 14px;
  }
---

# End-to-End App-Managed TLS on EKS

## AWS Private CA · cert-manager · Spring Boot · Telepresence

---

## What We Want to Achieve

- True **end-to-end encryption** - apps terminate TLS themselves, no proxy boundaries
- **Fully automated** certificate lifecycle - no manual rotation, no downtime
- Strong **security posture** - private keys never leave their trust boundary
- **Developer experience** preserved - local development against the cluster still works

### What We'll Cover

1. Architecture - how traffic flows
2. Certificate infrastructure - PCA hierarchy + cert-manager CSI driver
3. How apps use the certificates - Spring Boot SSL Bundles, TLS vs mTLS
4. Telepresence - local development with app-managed TLS

---


## This Is a Reference Architecture, Not a Prescription

Each layer is independently adoptable - pick what fits your environment:

- Already have a CA? Skip the PCA hierarchy, point cert-manager at yours
- Don't need mTLS? Drop `client-auth`, use TLS-only - same cert infrastructure works
- Already using cert-manager? Just add the CSI driver and PCA issuer plugin
- Have a different dev cert workflow? The Lambda approach is one option, not the only one

The goal is to show what the pieces are and how they fit together.

---


# Architecture

---

## Traffic Flow - Encrypted at Every Segment

```
        Client (browser/curl)
            |
            |  HTTPS :443 (ACM public cert, server-auth only)
            v
  +---------------------+
  |         ALB         |  Terminates public TLS,
  |  (internet-facing)  |  re-encrypts to pod,
  +---------------------+  Provisioned by AWS LB Controller
            |
            |  HTTPS :8443 (PCA cert, server-auth only - ALB doesn't send client cert)
            v
  +---------------------+
  |  greeting-service   |  App terminates TLS,
  |  (Spring Boot)      |  calls quote-service over mTLS
  +---------------------+
            |
            |  mTLS :8443 (PCA certs, client-auth: NEED)
            v
  +---------------------+
  |    quote-service    |  App terminates TLS,
  |    (Spring Boot)    |  verifies greeting's client cert
  +---------------------+
```

- Every segment is TLS-encrypted. Health checks use a separate plain HTTP port (8080)
- ALB → pod is server-auth only (ALB doesn't present a client cert)
- Pod → pod is full mTLS (both sides present and verify certs via shared root CA)

---


# Certificate Infrastructure

---

## PCA Hierarchy - Separation of Trust

```
  Root CA (e2e-tls-demo-root-ca)
    |
    |--- Cluster CA (e2e-tls-demo-cluster-ca)
    |      |--- greeting-service cert    (via cert-manager CSI driver)
    |      |--- quote-service cert       (via cert-manager CSI driver)
    |
    |--- Dev CA (e2e-tls-demo-dev-ca)
           |--- developer local certs    (via Lambda + Secrets Manager)
```

- **Root CA** (general-purpose mode) - signs subordinate CAs only, never issues leaf certs
- **Cluster CA** (short-lived mode, certs ≤7 days) - cert-manager issues pod certs automatically
- **Dev CA** (short-lived mode, certs ≤7 days) - Lambda issues developer certs, stored in Secrets Manager
- All certs chain to the same root --> **mutual trust is automatic**
- Subordinates use `PathLen0` - cannot create further sub-CAs

---

## The Three Components

Three Kubernetes extension points, all installed via Helm:

- **cert-manager** - Kubernetes operator (CRDs + controllers) that orchestrates certificate lifecycle: CSR creation, CA submission, renewal
- **aws-privateca-issuer** - cert-manager external issuer plugin that calls the AWS PCA API. cert-manager has a plugin interface for third-party CA backends (Vault, Venafi, Google CAS, etc.)
- **cert-manager CSI driver** - Kubernetes CSI (Container Storage Interface) driver. Same plugin interface as EBS/EFS, but instead of mounting a disk, it generates a private key on the node, gets it signed via cert-manager, and writes the cert to a tmpfs volume inside the pod

```bash
helm install cert-manager jetstack/cert-manager --set crds.enabled=true
helm install cert-manager-csi-driver jetstack/cert-manager-csi-driver
helm install aws-pca-issuer awspca/aws-privateca-issuer
```

---

## cert-manager CSI Driver - How Pods Get Certs

```
  Pod startup
    |
    v
  CSI driver ----> cert-manager ----> aws-privateca-issuer ----> AWS PCA
    |                                                            (cluster CA)
    |                                                                |
    v                                                                |
  Pod filesystem  <----------  cert written to tmpfs  <--------------+
  <mount-path>/tls.crt, tls.key, ca.crt
```

1. Pod spec declares CSI volume with cert attributes (issuer, DNS names, duration)
2. CSI driver generates key on the node, requests cert via cert-manager → AWS PCA
3. Cert written to pod tmpfs at configurable mount path (e.g. `/certs/`)
4. Same cert serves as both server and client identity (PCA certs include both EKUs - Extended Key Usages)

---

## CSI Driver - Security Properties

- 🔒 **In-memory only** (tmpfs) - keys never written to disk on the node
- 🔒 **Key never leaves the node** - generated locally by CSI driver
- 🔒 **Ephemeral** - destroyed when pod terminates, no Kubernetes Secrets in etcd
- 🔒 **Per-pod unique keys** - each pod gets its own key pair, even replicas of the same service
- 🔒 **Node failure** - pod rescheduled on new node gets a brand new key + cert (no key migration, old key gone from RAM)

---

## Certificate Rotation - Zero Downtime

```
  CSI driver detects cert approaching expiry (renew at 4h remaining)
    |
    +----> requests new cert from cert-manager --> AWS PCA
    |
    +----> writes new cert to pod tmpfs
    |
    +----> Spring Boot detects file change --> hot-reloads SSL context
```

- **Duration**: 24 hours (configurable via `csi.cert-manager.io/duration`)
- **Renew before**: 4 hours remaining (configurable via `csi.cert-manager.io/renew-before`)
- **No pod restart** - Spring Boot `reload-on-update: true` handles it
- Fully automated - no human intervention

---


# How Apps Use the Certificates

---

## Spring Boot SSL Bundles + mTLS

```yaml
server:
  port: 8443
  ssl:
    bundle: server
    client-auth: NEED    # Require client certificate (internal services)

spring:
  ssl:
    bundle:
      pem:
        server:                              # Incoming TLS
          keystore:
            certificate: /certs/tls.crt
            private-key: /certs/tls.key
          truststore:
            certificate: /certs/ca.crt
          reload-on-update: true
        client:                              # Outgoing calls to other services
          keystore:
            certificate: /certs/tls.crt      # Present as client identity
            private-key: /certs/tls.key
          truststore:
            certificate: /certs/ca.crt
```

- Same cert/key pair serves both server and client identity
- `server` bundle terminates incoming TLS; `client` bundle authenticates outgoing calls
- Port **8080** runs plain HTTP for health checks only

---

## Using the Client Bundle in Code

```java
@Bean
public RestClient restClient(SslBundles sslBundles) {
    SSLContext sslContext = sslBundles.getBundle("client").createSslContext();
    HttpClient httpClient = HttpClient.newBuilder()
            .sslContext(sslContext).build();
    return RestClient.builder()
            .baseUrl("https://quote-service.quote-service-ns.svc.cluster.local:8443")
            .requestFactory(new JdkClientHttpRequestFactory(httpClient)).build();
}
```

The `client` bundle's SSLContext includes both the truststore (verify server) and keystore (present client cert).

---

## mTLS Flow + ALB Constraint

```
greeting-service --> quote-service
  1. quote presents server cert --> greeting verifies via client truststore ✅
  2. quote demands client cert  --> greeting presents via client keystore  ✅
  3. quote verifies greeting's cert via server truststore (same root CA)  ✅
```

ALB terminates and re-encrypts TLS but **does not present a client certificate**:

| | ALB-facing services | Internal-only services |
|---|---|---|
| Example | greeting-service | quote-service |
| `client-auth` | not set (default NONE) | `NEED` |
| Incoming TLS | Server-auth only | Full mTLS |

- **Server-auth TLS from ALB + mTLS between services** covers both the ingress and service-to-service segments without exposing private CA certs to external clients

---

## TLS vs mTLS - It's a Choice

| | TLS (server-auth only) | mTLS (mutual auth) |
|---|---|---|
| Server presents cert | ✅ | ✅ |
| Client presents cert | ❌ | ✅ |
| Client verifies server identity | ✅ | ✅ |
| Server verifies client identity | ❌ | ✅ |
| Service-to-service via ALB (`https://quote.example.com`) | Works | Not possible (ALB strips client cert) |
| Service-to-service via FQDN (`https://quote-service.ns.svc:8443`) | Works | Works |
| Spring Boot config | `client-auth` not set | `client-auth: NEED` |

Both are valid choices:
- **TLS only**: simpler setup, all service-to-service calls can go through ALB if desired, no client certs needed
- **mTLS**: stronger security - services cryptographically verify the caller's identity, but requires direct pod-to-pod communication

This demo uses mTLS between services to show the full capability. Dropping to TLS-only is a config change (`client-auth: NEED` → remove it).

---

## Onboarding a New Service

Add a CSI volume to the deployment - no separate Certificate CR or Secret:

```yaml
containers:
  - name: my-service
    volumeMounts:
      - name: tls
        mountPath: /certs    # configurable - match your application.yml paths
        readOnly: true
volumes:
  - name: tls
    csi:
      driver: csi.cert-manager.io
      readOnly: true
      volumeAttributes:
        csi.cert-manager.io/issuer-name: aws-pca-issuer
        csi.cert-manager.io/issuer-kind: AWSPCAClusterIssuer
        csi.cert-manager.io/issuer-group: awspca.cert-manager.io
        csi.cert-manager.io/dns-names: my-service.my-ns.svc.cluster.local
        csi.cert-manager.io/duration: "24h"
        csi.cert-manager.io/renew-before: "4h"
```

Then configure SSL Bundles in `application.yml` + expose ports 8443 and 8080.

---


# Telepresence
### Local Development Against Remote Clusters

---

## What Is Telepresence?

A tool that connects your **local machine** to a remote Kubernetes cluster:

- **DNS resolution** - use cluster DNS names (`service-a.ns.svc.cluster.local`) from your laptop
- **Network routing** - traffic to cluster IPs is tunneled transparently
- **Intercepts** - route cluster traffic to your local machine for development

```
  Local Machine                                       EKS Cluster
  +-------------------+     TLS tunnel via      +------------------------+
  |  Your app         |     kubectl port-fwd    |  Traffic Manager       |
  |  Telepresence     | <=====================  |  Traffic Agent         |
  |  daemon + DNS     |                         |  (injected sidecar)    |
  +-------------------+                         +------------------------+
```

---

## Two Intercept Modes

### Global Intercept - all traffic to your local machine
```bash
telepresence intercept service-a --port 8080:8080
# ALL requests to service-a now hit your local app
```

### Header-Based Intercept - only matching requests
```bash
telepresence intercept service-a --port 8080:8080 --http-header x-dev=local

# With header --> local machine
curl -H "x-dev: local" http://service-a.ns:8080    # --> your laptop

# Without header --> in-cluster service
curl http://service-a.ns:8080                        # --> cluster pod
```

Multiple developers can intercept the **same service** simultaneously with different header values - no conflicts.

Note: header-based intercepts require the agent to read HTTP headers, so they only work with plain HTTP traffic. With app-managed TLS (both TLS and mTLS), traffic is encrypted and headers are unreadable - only global intercepts work.

---

## Telepresence + App-Managed TLS

---

## The Requirement

For Telepresence to work with app-managed TLS, the locally running service must:

1. **Present a cert with the same SAN** as the in-cluster service (e.g. `greeting-service.greeting-service-ns.svc.cluster.local`)
2. **Chain to the same root CA** so in-cluster services trust it (and vice versa)
3. **Include a client keystore** so it can authenticate via mTLS when calling other services

Without this, the intercepted traffic fails TLS handshake - the calling service expects a cert matching the in-cluster identity.

With TLS-only (no mTLS), requirements simplify:
- Point 3 is not needed (no client cert required)
- If outbound calls go via ALB, point 2 is also not needed (ACM certs are publicly trusted)

---

## Dev Certificates - One Possible Approach

- A **dedicated dev CA** (subordinate to the same root) issues dev certs - optional but recommended for separation from the cluster CA. The cluster CA could issue dev certs too, but a separate dev CA lets you apply different policies (shorter validity, restricted SANs, independent revocation)
- An **admin or platform team** runs a Lambda that generates certs and stores them in **Secrets Manager**
- Developers only pull pre-issued certs - they never interact with PCA directly

```bash
# Admin/platform: Lambda issues cert from dev CA, stores in Secrets Manager
./scripts/request-dev-cert.sh greeting-service

# Developer: pulls cert to local machine
./scripts/fetch-dev-cert.sh greeting-service

# Developer: runs locally with the cert
./scripts/run-local.sh greeting-service
```

- Dev certs valid for **7 days** (short-lived CA mode)
- Developers only need `secretsmanager:GetSecretValue` - no PCA access
- Separation of concerns: platform team controls issuance, developers consume certs

---

## Live Demo

See [demo-runbook.md](./e2e-tls-demo/demo-runbook.md) for the guided walkthrough:

1. Show AWS infrastructure (PCAs, ACM cert, ALB)
2. Verify pods running without sidecars
3. Inspect pod certificate (SAN, issuer, EKUs)
4. Hit the public endpoint - full chain works
5. **Prove mTLS is enforced** - curl without client cert → `certificate required`
6. Issue and fetch dev cert via Lambda + Secrets Manager
7. Compare dev cert with pod cert - same SAN, different issuer, same root CA
8. Telepresence connect + global intercept
9. Run local service with dev cert
10. Test - traffic routed to local, local calls quote-service over mTLS
