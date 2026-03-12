# E2E TLS Demo

End-to-end TLS encryption from ALB to Spring Boot pods using AWS Private CA, cert-manager, and Route53.

## Architecture

```
┌──────────┐    ┌─────────┐    ┌─────────────────┐    ┌──────────────────┐    ┌───────────────────┐
│ Internet │───▶│ Route53 │───▶│ ALB (ACM cert)  │───▶│ greeting-service │───▶│  quote-service    │
└──────────┘    └─────────┘    │ Public TLS :443 │    │ PCA cert :8443   │    │  PCA cert :8443   │
                               └─────────────────┘    └──────────────────┘    └───────────────────┘
                                      │                       │                        │
                                      │                       │                        │
                               Terminates public       Terminates TLS          Terminates TLS
                               TLS, re-encrypts        from ALB                from greeting-svc
                               to pods (HTTPS)
```

### Traffic Flow

1. **Internet → ALB**: Public TLS terminated using ACM certificate for `greeting.<your-domain>`
2. **ALB → greeting-service**: Re-encrypted using `backend-protocol: HTTPS` annotation; ALB connects to pod on port 8443
3. **greeting-service → quote-service**: Internal TLS using PCA-issued certificates; services trust each other via shared CA

### Health Checks

ALB health checks use a separate HTTP port (8080) to avoid certificate validation complexity:
- Main traffic: port 8443 (HTTPS)
- Health checks: port 8080 (HTTP) → `/actuator/health`

## Certificate Infrastructure

### Certificate Chain

```
AWS Private CA (root, general purpose mode)
  │
  ├── greeting-service-tls
  │     ├── tls.crt  (service certificate)
  │     ├── tls.key  (private key)
  │     └── ca.crt   (CA public certificate)
  │
  └── quote-service-tls
        ├── tls.crt
        ├── tls.key
        └── ca.crt
```

### Components

| Component | Purpose |
|-----------|---------|
| AWS Private CA | Root CA that issues certificates (general purpose mode for certs > 7 days) |
| cert-manager | Kubernetes-native certificate lifecycle management |
| cert-manager CSI driver | Mounts certificates directly into pods via CSI volume (no Secrets) |
| aws-privateca-issuer | cert-manager plugin that bridges to AWS PCA (uses Pod Identity for auth) |
| AWSPCAClusterIssuer | Cluster-wide issuer CR that connects cert-manager to your PCA |

### How cert-manager CSI Driver Works with AWS PCA

The CSI driver provisions certificates directly into pod filesystems — no Kubernetes Secrets involved:

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

**Benefits over Secret-based approach:**

| Aspect | CSI Driver | Certificate CR + Secret |
|--------|-----------|------------------------|
| Secrets in etcd | ❌ None | ✅ Stored in etcd |
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

No pod restart required — certificates rotate seamlessly.

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
- `/certs/tls.crt` — service certificate
- `/certs/tls.key` — private key
- `/certs/ca.crt` — CA certificate (for trusting other services)

### Spring Boot SSL Bundles

Spring Boot 3.1+ SSL bundles provide a clean way to configure TLS:

```yaml
# application.yml
server:
  port: 8443
  ssl:
    bundle: server

management:
  server:
    port: 8080
    ssl:
      enabled: false  # Health checks on plain HTTP

spring:
  ssl:
    bundle:
      pem:
        # Server bundle - for terminating incoming TLS
        server:
          keystore:
            certificate: /certs/tls.crt
            private-key: /certs/tls.key
          truststore:
            certificate: /certs/ca.crt
          reload-on-update: true  # Hot-reload on cert rotation

        # Client bundle - for calling other services over TLS
        client:
          truststore:
            certificate: /certs/ca.crt
```

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

The `client` bundle's truststore contains `ca.crt`, allowing greeting-service to verify quote-service's certificate was signed by the same CA.

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
./setup.sh
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
./teardown.sh
```

---

## Telepresence Integration

Telepresence allows you to develop locally while connected to the cluster network. There are two modes:

### 1. Connect Mode — Call In-Cluster Services from Local Machine

Use this when you want to call services running in the cluster from your local machine.

**Quick start with script:**
```bash
./call-service.sh greeting   # calls greeting-service
./call-service.sh quote      # calls quote-service
```

The script handles Telepresence connection and CA cert extraction automatically.

**Manual setup:**

Connect to the cluster:
```bash
telepresence connect
```

**Extract the CA certificate:**
```bash
kubectl get secret greeting-service-tls -n greeting-service-ns \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```

**Call services using cluster DNS:**
```bash
# Call greeting-service
curl --cacert ca.crt https://greeting-service.greeting-service-ns.svc.cluster.local:8443/greeting

# Call quote-service directly
curl --cacert ca.crt https://quote-service.quote-service-ns.svc.cluster.local:8443/quote
```

**What is `ca.crt`?**

It's the public certificate of the AWS Private CA root. Your client needs it to verify that the server's certificate was signed by a trusted authority. Without it, you get "certificate signed by unknown authority" errors. It's safe to distribute — only the CA's private key (which stays in AWS PCA) needs protection.

### 2. Intercept Mode — Route Cluster Traffic to Local Service

Use this when you want to intercept traffic destined for a cluster service and handle it locally.

**Quick start with script:**
```bash
# Terminal 1 - Run service locally with cluster certs
./run-local.sh greeting-service

# Terminal 2 - Start intercept
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

Extract the full certificate set:
```bash
# You need all three files to terminate TLS locally
kubectl get secret greeting-service-tls -n greeting-service-ns \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > tls.crt
kubectl get secret greeting-service-tls -n greeting-service-ns \
  -o jsonpath='{.data.tls\.key}' | base64 -d > tls.key
kubectl get secret greeting-service-tls -n greeting-service-ns \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```

**Run your local service with the cluster certs:**
```bash
java -jar greeting-service/target/*.jar \
  --spring.ssl.bundle.pem.server.keystore.certificate=tls.crt \
  --spring.ssl.bundle.pem.server.keystore.private-key=tls.key \
  --spring.ssl.bundle.pem.server.truststore.certificate=ca.crt \
  --spring.ssl.bundle.pem.client.truststore.certificate=ca.crt
```

**Start the intercept:**
```bash
telepresence intercept greeting-service -n greeting-service-ns --port 8443:8443
```

Now all traffic to `greeting-service` in the cluster routes to your local machine.

**Important considerations:**

- **Certificate SANs**: The certificates have SANs for `<service>.<namespace>.svc.cluster.local`. Telepresence routes DNS correctly, so hostname verification should work.
- **Certificate rotation**: Cluster certs rotate every 24h. For long dev sessions, re-fetch the certs periodically.
- **Health checks**: The ALB health checks go to port 8080 (HTTP). Make sure your local service also exposes the actuator on 8080, or the ALB will mark the target unhealthy.

**Disconnect when done:**
```bash
telepresence leave greeting-service
telepresence quit
```

---

## Onboarding a New Service

To add a new TLS-enabled service to this setup:

### 1. Create the Certificate CR

Create a `certificate.yaml` that tells cert-manager to request a certificate from AWS PCA:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-service-tls
  namespace: my-service-ns
spec:
  # Secret where cert-manager stores the issued certificate
  secretName: my-service-tls

  # Reference to the AWS PCA issuer (cluster-wide)
  issuerRef:
    name: aws-pca-issuer
    kind: AWSPCAClusterIssuer
    group: awspca.cert-manager.io

  # DNS names for the certificate (SANs)
  dnsNames:
    - my-service.my-service-ns.svc.cluster.local

  # Certificate lifetime and renewal
  duration: 24h
  renewBefore: 4h

  # Key algorithm (ECDSA P-256 recommended)
  privateKey:
    algorithm: ECDSA
    size: 256
```

Apply it:
```bash
kubectl apply -f certificate.yaml
```

cert-manager will:
1. Generate a private key
2. Create a CSR and send it to AWS PCA via aws-privateca-issuer
3. Store the issued cert in the Secret `my-service-tls`

Verify:
```bash
kubectl get certificate -n my-service-ns
kubectl get secret my-service-tls -n my-service-ns
```

### 2. Mount the Certificate in Your Deployment

Add volume and volumeMount to your deployment:

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
          secret:
            secretName: my-service-tls
```

This makes the certificates available at:
- `/certs/tls.crt` — your service's certificate
- `/certs/tls.key` — your service's private key
- `/certs/ca.crt` — CA certificate for trusting other services

### 3. Configure Spring Boot SSL Bundles

Add to your `application.yml`:

```yaml
server:
  port: 8443
  ssl:
    bundle: server

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
          truststore:
            certificate: /certs/ca.crt
```

### 4. Create the Service

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

### 5. (Optional) Expose via Ingress

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

- [ ] Certificate CR created and issued (`kubectl get certificate`)
- [ ] Secret contains `tls.crt`, `tls.key`, `ca.crt`
- [ ] Deployment mounts the secret at `/certs`
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
├── setup.sh              # Full infrastructure + app deployment
├── teardown.sh           # Clean up everything
├── run-local.sh          # Run service locally for Telepresence intercept
├── call-service.sh       # Call in-cluster services via Telepresence connect
├── diagrams/
│   └── e2e-tls-demo.drawio    # All diagrams (4 tabs: Architecture, Cert Flow, Connect, Intercept)
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
