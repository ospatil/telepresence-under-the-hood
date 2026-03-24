# E2E TLS Demo

End-to-end TLS encryption from ALB to Spring Boot pods using AWS Private CA, cert-manager, and Route53.

## Architecture

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
  |    (Spring Boot)    |  calls quote-service over mTLS
  +---------------------+
            |
            |  mTLS :8443 (PCA certs, client-auth: NEED)
            v
  +---------------------+
  |    quote-service    |  App terminates TLS,
  |    (Spring Boot)    |  verifies greeting's client cert
  +---------------------+
```

### Traffic Flow

1. **Internet → ALB**: Public TLS terminated using ACM certificate for `greeting.<your-domain>`
2. **ALB → greeting-service**: Re-encrypted using `backend-protocol: HTTPS` annotation; ALB connects to pod on port 8443. Server-auth only - ALB does not present a client certificate, so greeting-service has `client-auth` set to `NONE` for ALB-facing traffic (handled by the ingress path)
3. **greeting-service → quote-service**: Full mTLS using PCA-issued certificates. greeting-service presents its cert as client identity; quote-service verifies it via the shared root CA (`client-auth: NEED`)

### Health Checks

ALB health checks use a separate HTTP port (8080) to avoid certificate validation complexity:
- Main traffic: port 8443 (HTTPS)
- Health checks: port 8080 (HTTP) → `/actuator/health`

### ALB and mTLS - Design Trade-off

ALB (L7) terminates TLS and re-encrypts to backends, but does not present a client certificate. This creates two categories of services:

- **ALB-facing services** (e.g. greeting-service): cannot set `client-auth: NEED` - ALB won't satisfy it
- **Internal-only services** (e.g. quote-service): can and should set `client-auth: NEED` for full mTLS

The ALB → pod leg is still encrypted (server-auth TLS), but not mutually authenticated. For full mTLS on the ingress path, you'd need NLB (L4 passthrough) instead of ALB - but you'd lose ALB features like path/host routing, WAF, and sticky sessions. For most workloads, server-auth TLS from ALB + mTLS between services is the right balance.

### Why Not Use ALB/Custom Domain URLs for Service-to-Service Calls?

Services call each other directly using in-cluster DNS (e.g. `quote-service.quote-service-ns.svc.cluster.local:8443`) rather than going through the ALB or a public domain. Routing service-to-service traffic through the ALB has several downsides:

- **Loses mTLS identity**: ALB terminates TLS and re-establishes a new session - the calling service's client cert is stripped, so the receiving service can't verify who's calling
- **Public exposure**: Internal backend services would need their own ingress, creating an unnecessary public attack surface
- **Internet round-trip**: Traffic goes out to the internet and back in, adding latency to every call
- **Cost**: ALB charges per request and per hour; direct pod-to-pod calls are free
- **Fragility**: Adds dependency on DNS, ALB health, and internet connectivity for internal communication

Direct pod-to-pod calls via in-cluster DNS preserve mTLS identity, stay within the cluster network, and have no external dependencies. Telepresence provides the same direct access from a developer's local machine.

## Certificate Infrastructure

### Certificate Chain

```
AWS Private CA Root (e2e-tls-demo-root-ca)
  │
  ├── Subordinate CA: e2e-tls-demo-cluster-ca
  │     ├── greeting-service cert (via cert-manager CSI driver)
  │     └── quote-service cert (via cert-manager CSI driver)
  │
  └── Subordinate CA: e2e-tls-demo-dev-ca
        └── developer local certs (via Lambda + Secrets Manager)
```

Each service pod receives:
- `tls.crt` - service certificate (issued by cluster CA)
- `tls.key` - private key (generated in-memory on the node)
- `ca.crt` - root CA certificate (for trusting all certs in the hierarchy)

### Components

Three Kubernetes extension points work together to deliver certificates to pods:

- **cert-manager** - a Kubernetes operator (CRDs + controllers) that orchestrates certificate lifecycle: CSR creation, CA submission, renewal
- **aws-privateca-issuer** - a cert-manager external issuer plugin. cert-manager has a plugin interface for third-party CA backends; this one calls the AWS PCA `IssueCertificate` API. Similar plugins exist for Vault, Venafi, Google CAS, etc.
- **cert-manager CSI driver** - a Kubernetes CSI (Container Storage Interface) driver. CSI is the standard storage plugin interface (same as EBS, EFS). Instead of mounting a disk, this driver generates a private key + CSR on the node, submits it to cert-manager, and writes the signed cert to a tmpfs volume inside the pod. The private key never leaves the node.

| Component | Purpose |
|-----------|---------|
| AWS Private CA (root) | Root of trust - signs subordinate CAs, never issues leaf certs directly |
| AWS Private CA (cluster subordinate) | Issues service certificates via cert-manager CSI driver |
| AWS Private CA (dev subordinate) | Issues developer local certificates via Lambda |
| cert-manager | Kubernetes-native certificate lifecycle management |
| cert-manager CSI driver | Mounts certificates directly into pods via CSI volume (no Secrets) |
| aws-privateca-issuer | cert-manager plugin that bridges to AWS PCA (uses Pod Identity for auth) |
| AWSPCAClusterIssuer | Cluster-wide issuer CR that connects cert-manager to the cluster subordinate CA |
| Lambda (issue-dev-cert) | Issues dev certs from the dev CA and stores them in Secrets Manager |

### How cert-manager CSI Driver Works with AWS PCA

The CSI driver provisions certificates directly into pod filesystems - no Kubernetes Secrets involved:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Pod startup                                                                  │
│                                                                              │
│  ┌──────────────┐     ┌─────────────────────┐     ┌───────────────────────┐  │
│  │ CSI driver   │────▶│ aws-privateca-issuer│────▶│ AWS Private CA        │  │
│  │ (kubelet)    │     │ (plugin)            │     │ (AWS API)             │  │
│  └──────────────┘     └─────────────────────┘     └───────────────────────┘  │
│         │                      │                                             │
│         │ reads volume         │ uses Pod Identity                           │
│         │ attributes           │ for AWS auth                                │
│         ▼                      │                                             │
│  ┌──────────────┐              │                                             │
│  │ Pod spec     │──────────────┘                                             │
│  │ CSI volume   │                                                            │
│  └──────────────┘                                                            │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Flow:**

1. Pod spec declares a CSI volume with cert attributes (issuer, DNS names, duration)
2. Kubelet calls cert-manager CSI driver to mount the volume
3. CSI driver requests certificate from cert-manager
4. cert-manager delegates to aws-privateca-issuer (based on issuer config)
5. aws-privateca-issuer calls AWS PCA API (`IssueCertificate`)
6. Certificate is written directly to pod filesystem at mount path
7. CSI driver handles renewal automatically before expiry

**Security properties:**

- **In-memory only (tmpfs)**: The CSI driver creates a tmpfs volume - certificates and private keys are stored in memory, never written to disk on the node
- **Private key never leaves the node**: Keys are generated locally on the node by the CSI driver and never transmitted over the network
- **Ephemeral lifecycle**: Volume is created at pod startup and destroyed at pod termination - no key material persists after the pod is gone
- **No Kubernetes Secrets**: Nothing is stored in etcd - eliminates an entire class of secret-sprawl risks
- **Node failure recovery**: If a node dies and the pod is rescheduled on another node, the CSI driver generates a brand new private key and gets a fresh cert issued. There is no key migration - the old key is gone (it was in RAM). The new cert has a different key pair but the same SAN and chains to the same root CA, so all trust relationships still work. Every pod restart gets a fresh key pair, limiting the blast radius of any key compromise to that pod's lifetime.

**Benefits over Secret-based approach:**

| Aspect | CSI Driver | Certificate CR + Secret |
|--------|-----------|------------------------|
| Secrets in etcd | ❌ None | ✅ Stored in etcd |
| Key storage | ✅ In-memory (tmpfs) | ❌ On disk (etcd + node) |
| Key leaves node | ❌ Never | ✅ Via API server |
| Per-pod unique certs | ✅ Each pod gets its own | ❌ Shared Secret |
| Certificate lifecycle | ✅ Tied to pod | ❌ Independent of pod |
| Setup complexity | ✅ All in deployment.yaml | ❌ Separate Certificate CR |

**Installation (three Helm charts):**

```bash
# 1. Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

# 2. Install cert-manager CSI driver
helm install cert-manager-csi-driver jetstack/cert-manager-csi-driver \
  --namespace cert-manager

# 3. Install aws-privateca-issuer
helm install aws-privateca-issuer awspca/aws-privateca-issuer \
  --namespace cert-manager
```

**AWSPCAClusterIssuer CR (connects cert-manager to your PCA):**

```yaml
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAClusterIssuer
metadata:
  name: aws-pca-issuer
spec:
  arn: arn:aws:acm-pca:ca-central-1:123456789012:certificate-authority/xxxxx
  region: ca-central-1
```

### Certificate Rotation

Certificates are configured with:
- **Duration**: 24 hours
- **Renew before**: 4 hours (CSI driver renews when 4h remaining)

**Rotation flow:**
1. CSI driver detects certificate approaching expiry
2. CSI driver requests new certificate from cert-manager/AWS PCA
3. New cert is written directly to pod filesystem
4. Spring Boot detects file change and hot-reloads (via `reload-on-update: true`)

No pod restart required - certificates rotate seamlessly.

## How Java Services Use Certificates

### CSI Volume Mount

Certificates are provisioned directly into pods via CSI driver:

```yaml
# deployment.yaml
volumes:
  - name: tls
    csi:
      driver: csi.cert-manager.io
      readOnly: true
      volumeAttributes:
        csi.cert-manager.io/issuer-name: aws-pca-issuer
        csi.cert-manager.io/issuer-kind: AWSPCAClusterIssuer
        csi.cert-manager.io/issuer-group: awspca.cert-manager.io
        csi.cert-manager.io/dns-names: greeting-service.greeting-service-ns.svc.cluster.local
        csi.cert-manager.io/duration: "24h"
        csi.cert-manager.io/renew-before: "4h"

volumeMounts:
  - name: tls
    mountPath: /certs
    readOnly: true
```

This makes certificates available at:
- `/certs/tls.crt` - service certificate
- `/certs/tls.key` - private key
- `/certs/ca.crt` - CA certificate (for trusting other services)

### Spring Boot SSL Bundles

Spring Boot 3.1+ SSL bundles provide a clean way to configure TLS:

```yaml
# application.yml
server:
  port: 8443
  ssl:
    bundle: server
    client-auth: NEED  # Require client certificate for mTLS

management:
  server:
    port: 8080
    ssl:
      enabled: false  # Health checks on plain HTTP

spring:
  ssl:
    bundle:
      pem:
        # Server bundle - for terminating incoming TLS and verifying client certs
        server:
          keystore:
            certificate: /certs/tls.crt
            private-key: /certs/tls.key
          truststore:
            certificate: /certs/ca.crt
          reload-on-update: true  # Hot-reload on cert rotation

        # Client bundle - for calling other services over TLS (presents client cert)
        client:
          keystore:
            certificate: /certs/tls.crt
            private-key: /certs/tls.key
          truststore:
            certificate: /certs/ca.crt
```

### Server vs Client Certificates

The PCA-issued certs include both `TLS Web Server Authentication` and `TLS Web Client Authentication` extended key usages, so the same cert/key pair serves as both server and client identity. The `server` bundle uses it to terminate incoming TLS; the `client` bundle uses it to authenticate when calling other services.

### mTLS Between Services

With `client-auth: NEED`, every service-to-service call is mutually authenticated:

```
greeting-service --> quote-service
  1. quote-service presents its server cert (SAN: quote-service.quote-service-ns.svc.cluster.local)
     greeting verifies it via client truststore (root CA) ✅
  2. quote-service demands a client cert (client-auth: NEED)
     greeting presents its cert via client keystore ✅
  3. quote-service verifies greeting's cert via server truststore (same root CA) ✅
```

Both certs chain to the same PCA root CA, so mutual trust is automatic. The SAN doesn't need to match for client auth - it just needs to chain to a trusted CA. SAN matching only applies to server identity (hostname verification).

### Using the Client Bundle

greeting-service calls quote-service over HTTPS using the client SSL bundle:

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

The `client` bundle's truststore contains `ca.crt`, allowing greeting-service to verify quote-service's certificate. The `client` bundle's keystore contains the same cert/key pair as the server bundle, which greeting-service presents as its client identity when quote-service requires mutual TLS.

## Prerequisites

- EKS cluster with ALB Ingress Controller installed
- kubectl connected to cluster
- AWS CLI v2, Helm 3.6+, Docker, Maven, jq
- Route53 hosted zone for your domain

## Quick Start

```bash
# 1. Copy and configure environment
cp .env.example .env
# Edit .env with your AWS_ACCOUNT_ID, DOMAIN, HOSTED_ZONE_ID

# 2. Run setup
./scripts/setup.sh
```

## Test

```bash
curl https://greeting.${DOMAIN}/greeting
```

Expected response:
```json
{
  "message": "Hello from greeting-service!",
  "quote": "Stay hungry, stay foolish.",
  "quoteSource": "quote-service"
}
```

## Teardown

```bash
./scripts/teardown.sh
```

---

## Telepresence Integration

Telepresence allows you to develop locally while connected to the cluster network. There are two modes:

### Dev Certificate Issuance

The cert-manager CSI driver stores private keys in tmpfs (in-memory only) - they never touch disk and never leave the node. Extracting certs from pods via `kubectl exec` would undermine this security model by copying the private key over the network onto your laptop.

Instead, a Lambda function issues dev certificates from the dev subordinate CA and stores them in AWS Secrets Manager. No private keys are generated on any developer or admin machine:

```bash
# Admin or dev: request a cert (Lambda issues it, stores in Secrets Manager)
./scripts/request-dev-cert.sh greeting-service

# Dev: pull the cert to local machine
./scripts/fetch-dev-cert.sh greeting-service
```

This creates `.certs/greeting-service/tls.crt`, `tls.key`, and `ca.crt`. The cert has the same SAN as the in-cluster service (`greeting-service.greeting-service-ns.svc.cluster.local`) and is valid for 7 days. Since it chains to the same root CA, in-cluster services trust it automatically. The Lambda skips issuance if a valid cert already exists.

Developers need `secretsmanager:GetSecretValue` permission. Only the Lambda needs PCA issuance permissions.

You can inspect certificates with:
```bash
./scripts/inspect-cert.sh local greeting-service   # inspect local dev cert
./scripts/inspect-cert.sh pod greeting-service     # inspect cert inside the pod
```

### 1. Connect Mode - Call In-Cluster Services from Local Machine

Use this when you want to call services running in the cluster from your local machine.

**Quick start with script:**
```bash
./scripts/call-service.sh greeting   # calls greeting-service
./scripts/call-service.sh quote      # calls quote-service
```

The script handles Telepresence connection and CA cert download from PCA automatically.

**Manual setup:**

Connect to the cluster:
```bash
telepresence connect
```

**Download the CA certificate from PCA:**
```bash
mkdir -p .certs/greeting-service
aws acm-pca get-certificate-authority-certificate \
  --certificate-authority-arn "$ROOT_CA_ARN" \
  --region ca-central-1 \
  --query 'Certificate' --output text > .certs/greeting-service/ca.crt
```

**Call services using cluster DNS:**
```bash
# Call greeting-service
curl --cacert .certs/greeting-service/ca.crt https://greeting-service.greeting-service-ns.svc.cluster.local:8443/greeting

# Call quote-service directly
curl --cacert .certs/greeting-service/ca.crt https://quote-service.quote-service-ns.svc.cluster.local:8443/quote
```

**What is `ca.crt`?**

It's the public certificate of the AWS Private CA root. Your client needs it to verify that the server's certificate was signed by a trusted authority. Without it, you get "certificate signed by unknown authority" errors. It's safe to distribute - only the CA's private key (which stays in AWS PCA) needs protection.

### 2. Intercept Mode - Route Cluster Traffic to Local Service

Use this when you want to intercept traffic destined for a cluster service and handle it locally. Note: only global intercepts work with app-managed TLS (see important considerations below).

**Quick start with script:**
```bash
# Terminal 1 - Get cert and run service locally
./scripts/request-dev-cert.sh greeting-service
./scripts/fetch-dev-cert.sh greeting-service
./scripts/run-local.sh greeting-service

# Terminal 2 - Start intercept (global - all traffic routes to local)
telepresence connect -n greeting-service-ns
telepresence intercept greeting-service --port 8443:8443

# Terminal 3 - Test (traffic now routes to local)
# Option A: External URL (no cert needed, ALB handles TLS)
curl https://greeting.${DOMAIN}/greeting

# Option B: In-cluster DNS (requires CA cert)
curl --cacert .certs/greeting-service/ca.crt \
  https://greeting-service.greeting-service-ns.svc.cluster.local:8443/greeting
```

**Manual setup (if not using script):**

Issue a local certificate:
```bash
./scripts/request-dev-cert.sh greeting-service
./scripts/fetch-dev-cert.sh greeting-service
# Creates .certs/greeting-service/tls.crt, tls.key, ca.crt
```

**Run your local service with the locally-issued certs:**
```bash
java -jar greeting-service/target/*.jar \
  --spring.ssl.bundle.pem.server.keystore.certificate=.certs/greeting-service/tls.crt \
  --spring.ssl.bundle.pem.server.keystore.private-key=.certs/greeting-service/tls.key \
  --spring.ssl.bundle.pem.server.truststore.certificate=.certs/greeting-service/ca.crt \
  --spring.ssl.bundle.pem.client.truststore.certificate=.certs/greeting-service/ca.crt
```

**Start the intercept:**
```bash
telepresence intercept greeting-service --port 8443:8443
```

All traffic to `greeting-service` in the cluster routes to your local machine.

**Important considerations:**

- **Certificate SANs**: The locally-issued certificates have the same SANs as in-cluster certs (`<service>.<namespace>.svc.cluster.local`). Telepresence routes DNS correctly, so hostname verification works.
- **Certificate validity**: Dev certs are valid for 7 days (same as pod certs). The Lambda skips re-issuance if a valid cert exists; use `--force` with `request-dev-cert.sh` to re-issue.
- **Health checks**: The ALB health checks go to port 8080 (HTTP). Make sure your local service also exposes the actuator on 8080, or the ALB will mark the target unhealthy.
- **Header-based intercepts don't work with app-managed TLS**: The traffic agent operates at L7 (HTTP) for header-based intercepts but at L4 (TCP) for global intercepts. With header-based routing (`--http-header`), the agent needs to read HTTP headers to decide where to route traffic. But traffic arriving on port 8443 is TLS-encrypted - the agent sees a TLS ClientHello, not an HTTP request. It can't parse headers from encrypted bytes, so the TLS handshake fails. This breaks ALL traffic on the intercepted port (not just requests with the header) because the agent has replaced the app as the listener on 8443. Only global intercepts work with app-managed TLS - they proxy raw TCP bytes without inspecting traffic, so TLS passes through opaquely. Header-based intercepts work fine with Istio Ambient because ztunnel handles mTLS at the node level and delivers decrypted plain HTTP to the pod - the traffic agent can read headers and route accordingly.
**Disconnect when done:**
```bash
telepresence leave greeting-service
telepresence quit
```

---

## Onboarding a New Service

To add a new TLS-enabled service to this setup:

### 1. Add CSI Volume to Your Deployment

Declare the certificate inline in your pod spec - no separate Certificate CR or Secret needed:

```yaml
spec:
  template:
    spec:
      containers:
        - name: my-service
          volumeMounts:
            - name: tls
              mountPath: /certs
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
              csi.cert-manager.io/common-name: my-service
              csi.cert-manager.io/dns-names: my-service.my-service-ns.svc.cluster.local
              csi.cert-manager.io/duration: "24h"
              csi.cert-manager.io/renew-before: "4h"
              csi.cert-manager.io/key-algorithm: ECDSA
              csi.cert-manager.io/key-size: "256"
```

This makes the certificates available at:
- `/certs/tls.crt` - your service's certificate

**Note**: `dns-names` must be the full FQDN (e.g. `my-service.my-service-ns.svc.cluster.local`). The CSI driver passes this value directly into the certificate's SAN - it does not append `.svc.cluster.local` automatically. If you use just the short name, TLS hostname verification will fail when clients connect using the FQDN.
- `/certs/tls.key` - your service's private key
- `/certs/ca.crt` - CA certificate for trusting other services

### 2. Configure Spring Boot SSL Bundles

Add to your `application.yml`:

```yaml
server:
  port: 8443
  ssl:
    bundle: server
    client-auth: NEED  # Require client certificate for mTLS

management:
  server:
    port: 8080
    ssl:
      enabled: false

spring:
  ssl:
    bundle:
      pem:
        server:
          keystore:
            certificate: /certs/tls.crt
            private-key: /certs/tls.key
          truststore:
            certificate: /certs/ca.crt
          reload-on-update: true

        # Only needed if calling other TLS services
        client:
          keystore:
            certificate: /certs/tls.crt
            private-key: /certs/tls.key
          truststore:
            certificate: /certs/ca.crt
```

### 3. Create the Service

Expose both the HTTPS port and management port:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: my-service-ns
spec:
  type: ClusterIP
  selector:
    app: my-service
  ports:
    - name: https
      port: 8443
      targetPort: 8443
    - name: management
      port: 8080
      targetPort: 8080
```

### 4. (Optional) Expose via Ingress

If the service needs external access:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service
  namespace: my-service-ns
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-path: /actuator/health
    alb.ingress.kubernetes.io/healthcheck-port: "8080"
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: <acm-cert-arn>
    external-dns.alpha.kubernetes.io/hostname: my-service.example.com
spec:
  ingressClassName: alb
  rules:
    - host: my-service.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  name: https
```

### Checklist

- [ ] Deployment has CSI volume with cert-manager attributes (issuer, DNS names, duration)
- [ ] Pod mounts certs at `/certs` (tls.crt, tls.key, ca.crt)
- [ ] Spring Boot configured with SSL bundles
- [ ] Service exposes port 8443 (https) and 8080 (management)
- [ ] Health checks target port 8080 (HTTP)
- [ ] (If external) Ingress with `backend-protocol: HTTPS`

---

## Files Reference

```
e2e-tls-demo/
├── README.md
├── .env.example          # Environment template (copy to .env)
├── .gitignore
├── pca-hierarchy-alternative.md  # Design note: CA hierarchy rationale
├── scripts/
│   ├── setup.sh              # Full infrastructure + app deployment
│   ├── teardown.sh           # Clean up everything
│   ├── request-dev-cert.sh   # Invoke Lambda to issue dev cert → Secrets Manager
│   ├── fetch-dev-cert.sh     # Pull dev cert from Secrets Manager to local .certs/
│   ├── run-local.sh          # Run service locally for Telepresence intercept
│   ├── call-service.sh       # Call in-cluster services via Telepresence connect
│   └── inspect-cert.sh       # Inspect local dev certs or pod certs
├── lambda/
│   └── issue_dev_cert.py     # Lambda: issues cert from dev CA, stores in Secrets Manager
├── diagrams/
│   └── e2e-tls-demo.drawio   # All diagrams (4 tabs: Architecture, Cert Flow, Connect, Intercept)
├── greeting-service/
│   ├── pom.xml
│   ├── Dockerfile
│   ├── src/main/java/    # Spring Boot app
│   ├── src/main/resources/application.yml
│   └── k8s/
│       ├── deployment.yaml    # Includes CSI volume for certs
│       └── ingress.yaml       # ALB ingress with external-dns
└── quote-service/
    ├── pom.xml
    ├── Dockerfile
    ├── src/main/java/
    ├── src/main/resources/application.yml
    └── k8s/
        └── deployment.yaml    # Includes CSI volume for certs
```
