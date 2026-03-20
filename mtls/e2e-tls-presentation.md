---
marp: true
theme: default
paginate: true
backgroundColor: #fff
style: |
  section {
    font-size: 24px;
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
    font-size: 20px;
  }
  code {
    font-size: 18px;
  }
  pre {
    font-size: 16px;
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
3. How apps use the certificates - Spring Boot SSL Bundles
4. Telepresence - local development with app-managed TLS

---


# Architecture

---

## Traffic Flow - Encrypted at Every Segment

```
        Client (browser/curl)
            |
            |  HTTPS :443 (ACM public cert)
            v
  +---------------------+
  |         ALB         |  Terminates public TLS,
  |  (internet-facing)  |  re-encrypts to pod
  +---------------------+  Provisioned by AWS LB Controller
            |
            |  HTTPS :8443 (PCA cert, backend-protocol: HTTPS, target-type: ip)
            v
  +---------------------+
  |  greeting-service   |  App terminates TLS,
  |  (Spring Boot)      |  calls quote-service over HTTPS
  +---------------------+
            |
            |  HTTPS :8443 (PCA cert, mutual CA trust)
            v
  +---------------------+
  |    quote-service    |  App terminates TLS
  |    (Spring Boot)    |
  +---------------------+
```

Every segment is TLS-encrypted. Health checks use a separate plain HTTP port (8080).
DNS via Route53 resolves `greeting.<domain>` to the ALB.

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

- **Root CA** - signs subordinate CAs only, never issues leaf certs
- **Cluster CA** - cert-manager issues pod certs automatically
- **Dev CA** - Lambda issues developer certs, stored in Secrets Manager
- All certs chain to the same root --> **mutual trust is automatic**
- Subordinates use `PathLen0` - cannot create further sub-CAs

---

## cert-manager CSI Driver - How Pods Get Certs

```
  Pod startup
    |
    v
  CSI driver ----> cert-manager ----> aws-privateca-issuer ----> AWS PCA
    |                                                            (cluster CA)
    |  reads volume                                                  |
    |  attributes                                           issues certificate
    |                                                                |
    v                                                                |
  Pod filesystem  <----------  cert written to tmpfs  <--------------+
  /certs/tls.crt, tls.key, ca.crt
```

1. Pod spec declares CSI volume with cert attributes (issuer, DNS names, duration)
2. CSI driver requests certificate from cert-manager --> AWS PCA
3. Certificate written directly to pod filesystem at `/certs/`
4. CSI driver handles **renewal automatically** before expiry

---

## CSI Driver - Security Properties

Certificates live in **tmpfs** (in-memory only):

- 🔒 **In-memory only** - keys never written to disk on the node
- 🔒 **Key never leaves the node** - generated locally by CSI driver
- 🔒 **Ephemeral lifecycle** - destroyed when pod terminates
- 🔒 **No Kubernetes Secrets** - nothing stored in etcd

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

## Spring Boot SSL Bundles

```yaml
spring:
  ssl:
    bundle:
      pem:
        server:                              # Incoming TLS on port 8443
          keystore:
            certificate: /certs/tls.crt
            private-key: /certs/tls.key
          truststore:
            certificate: /certs/ca.crt       # Trust the root CA
          reload-on-update: true             # Hot-reload on cert rotation
        client:                              # Outgoing calls to other services
          truststore:
            certificate: /certs/ca.crt
```

- **`server` bundle** - terminates incoming TLS using the service's own cert
- **`client` bundle** - trusts any cert signed by the same root CA
- Port **8080** runs plain HTTP - health checks only

---

## How the App Uses Each Bundle

**Server bundle** - Spring Boot automatically terminates TLS on port 8443. No code needed:
```yaml
server:
  port: 8443
  ssl:
    bundle: server    # references the 'server' SSL bundle
```

**Client bundle** - used explicitly when calling other TLS services:
```java
@Bean
public RestClient restClient(SslBundles sslBundles) {
    SSLContext sslContext = sslBundles.getBundle("client").createSslContext();
    HttpClient httpClient = HttpClient.newBuilder()
            .sslContext(sslContext)
            .build();
    return RestClient.builder()
            .baseUrl("https://quote-service.quote-service-ns.svc.cluster.local:8443")
            .requestFactory(new JdkClientHttpRequestFactory(httpClient))
            .build();
}
```

The `client` bundle's truststore contains `ca.crt` (root CA) - verifies quote-service's cert.

---

## Onboarding a New Service

Add a CSI volume to the deployment - no separate Certificate CR or Secret:

```yaml
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

---

## Telepresence + App-Managed TLS

---

## Dev Certificates - One Possible Approach

A **Lambda** issues dev certs from the dev subordinate CA and stores them in Secrets Manager. Developers pull certs when needed:

```bash
# Lambda issues cert, stores in Secrets Manager
./scripts/request-dev-cert.sh greeting-service

# Developer pulls cert to local machine
./scripts/fetch-dev-cert.sh greeting-service

# Run locally with the cert
./scripts/run-local.sh greeting-service
```

- Dev certs valid for **30 days** - Lambda skips if valid cert exists
- Developers only need `secretsmanager:GetSecretValue` - no PCA access
- Private keys generated **inside Lambda**, stored in Secrets Manager

---

## Dev Certificate Flow

```
  Developer
  runs script
      |
      |  request-dev-cert.sh
      v
  +----------+          +----------------+          +-----------+
  |  Lambda  | -------> |  Dev CA        | -------> |  AWS PCA  |
  |          |          |  (subordinate) |          | (issue)   |
  +----+-----+          +----------------+          +-----------+
       |
       |  stores cert + key
       v
  +------------------+
  |  Secrets Manager |
  +--------+---------+
           |
           |  fetch-dev-cert.sh
           v
  +------------------+
  |  .certs/         |
  |    tls.crt       |
  |    tls.key       |
  |    ca.crt        |
  +------------------+
```

---

## Intercept Mode - Route Cluster Traffic to Local

```bash
# Terminal 1 - run service locally with dev cert
./scripts/run-local.sh greeting-service

# Terminal 2 - start global intercept
telepresence connect -n greeting-service-ns
telepresence intercept greeting-service --port 8443:8443

# Terminal 3 - test
curl https://greeting.example.com/greeting          # via ALB
curl --cacert .certs/greeting-service/ca.crt \       # via cluster DNS
  https://greeting-service.greeting-service-ns.svc.cluster.local:8443/greeting
```

- **Global intercepts only** - header-based intercepts break with app-managed TLS
- Traffic agent proxies at L4 (TCP) - TLS passes through opaquely
- Header-based requires L7 inspection - agent can't read encrypted headers

---

## Inspect Certificates

```bash
# Local dev cert
./scripts/inspect-cert.sh local greeting-service

# === Local dev cert (greeting-service) ===
# subject=CN=greeting-service
# issuer=CN=e2e-tls-demo-dev-ca          <-- issued by dev CA
# X509v3 Subject Alternative Name:
#     DNS:greeting-service.greeting-service-ns.svc.cluster.local

# Pod cert
./scripts/inspect-cert.sh pod greeting-service

# === Pod cert (greeting-service) ===
# subject=CN=greeting-service
# issuer=CN=e2e-tls-demo-cluster-ca      <-- issued by cluster CA
# X509v3 Subject Alternative Name:
#     DNS:greeting-service.greeting-service-ns.svc.cluster.local
```

Different issuers, same SAN, same root CA trust --> **mutual trust works**

---


# Summary

---

## What We Built

| Layer | Technology | Purpose |
|-------|-----------|---------|
| CA hierarchy | AWS Private CA | Root + cluster CA + dev CA |
| Pod certs | cert-manager CSI driver | In-memory, auto-rotating, per-pod |
| App TLS | Spring Boot SSL Bundles | Server + client TLS with hot-reload |
| ALB | ACM + `backend-protocol: HTTPS` | End-to-end encryption from internet |
| Dev certs | Lambda + Secrets Manager | Secure dev cert issuance, no key extraction |
| Local dev | Telepresence | Global intercepts with dev-CA-issued certs |

### Key Properties

- ✅ True end-to-end encryption - no plain text segments
- ✅ Private keys never leave their trust boundary (node or Lambda)
- ✅ Fully automated cert lifecycle - zero manual rotation
- ✅ Developer experience preserved - Telepresence keeps the inner loop fast

---


# Thank You

### Questions?
