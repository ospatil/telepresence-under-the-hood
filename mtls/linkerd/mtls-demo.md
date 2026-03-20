# East-West mTLS with Linkerd + Telepresence Demo

This extends the existing telepresence demo by adding automatic mTLS between service-a and service-b using Linkerd, then demonstrating that Telepresence intercepts still work seamlessly.

## Prerequisites

- Existing demo deployed (service-a and service-b running in cluster)
- cert-manager installed (v1.17+)
- Telepresence client and traffic manager (v2.25+)

## Architecture

```
Before (plain HTTP):
  service-a ──HTTP──▶ service-b

After (Linkerd mTLS):
  service-a ──▶ linkerd-proxy ══mTLS══▶ linkerd-proxy ──▶ service-b
                (sidecar)                (sidecar)

With Telepresence intercept (PERMISSIVE mode):
  local machine ──HTTP──▶ linkerd-proxy ══mTLS══▶ linkerd-proxy ──▶ service-b
  (no sidecar)            (in-cluster)            (sidecar)
```

Linkerd defaults to PERMISSIVE mTLS - it accepts both mTLS and plain HTTP. When Telepresence intercepts a pod, the intercepted traffic arrives as plain HTTP, and Linkerd handles it gracefully.

## Phase 1: Certificate Infrastructure

Linkerd requires a three-level certificate hierarchy:

```
Trust Anchor (Root CA) - 10 years, cert-manager managed
  └── Identity Issuer (Intermediate CA) - 1 year, cert-manager auto-rotates
        └── Workload Certificates - 24h, Linkerd auto-manages
```

We use cert-manager (already installed) to manage the trust anchor and identity issuer entirely in-cluster - no local cert generation needed.

### 1.1 Create cert-manager resources for Linkerd

```yaml
# linkerd-certs.yaml
---
# Bootstrap: a self-signed issuer to create the root CA
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
# Trust Anchor (Root CA) - 10 years
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: linkerd-trust-anchor
  namespace: linkerd
spec:
  isCA: true
  commonName: root.linkerd.cluster.local
  secretName: linkerd-trust-anchor
  duration: 87600h    # 10 years
  renewBefore: 8760h  # 1 year before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
# Issuer backed by the trust anchor
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: linkerd-trust-anchor
  namespace: linkerd
spec:
  ca:
    secretName: linkerd-trust-anchor
---
# Identity Issuer (Intermediate CA) - 1 year, auto-rotated
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: linkerd-identity-issuer
  namespace: linkerd
spec:
  isCA: true
  commonName: identity.linkerd.cluster.local
  secretName: linkerd-identity-issuer
  duration: 8760h     # 1 year
  renewBefore: 2160h  # 90 days before expiry
  dnsNames:
    - identity.linkerd.cluster.local
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - cert sign
    - crl sign
    - server auth
    - client auth
  issuerRef:
    name: linkerd-trust-anchor
    kind: Issuer
```

Apply:

```bash
kubectl create ns linkerd
kubectl apply -f linkerd-certs.yaml
```

Verify certificates are ready:

```bash
kubectl get certificates -n linkerd
# Both should show READY=True
```

### 1.2 Extract trust anchor for Linkerd Helm install

```bash
kubectl get secret linkerd-trust-anchor -n linkerd \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```

### Production Alternative: AWS Private CA

For production, replace the self-signed bootstrap with [aws-privateca-issuer](https://github.com/cert-manager/aws-privateca-issuer) backed by AWS Private CA. This gives you HSM-backed key storage, audit logging, and managed CA infrastructure.

**Important**: AWS PCA's `BlankEndEntityCertificate_APICSRPassthrough/V1` template (used for CA certs) sets `pathlen:0`. This means the original 3-level chain (PCA → trust anchor → identity issuer → workload certs) won't work - the trust anchor can't issue sub-CAs. The solution is to use PCA directly as the trust anchor, simplifying to a 2-level chain:

```
Self-signed (this demo):
  selfsigned-bootstrap → trust-anchor → identity-issuer → workload certs

AWS PCA (production):
  AWS PCA (trust anchor) → identity-issuer → workload certs
```

**Note on PCA mode**: Use `GENERAL_PURPOSE` mode (~$400/month) since the identity issuer is a CA cert with 1-year validity. `SHORT_LIVED_CERTIFICATE` mode (~$50/month) only supports certs ≤7 days.

Install the issuer plugin:

```bash
helm repo add awspca https://cert-manager.github.io/aws-privateca-issuer
helm install aws-pca-issuer awspca/aws-privateca-issuer -n cert-manager
```

Create the issuer:

```yaml
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAClusterIssuer
metadata:
  name: aws-pca-issuer
spec:
  arn: arn:aws:acm-pca:<region>:<account>:certificate-authority/<ca-id>
  region: <region>
```

Remove the `selfsigned-bootstrap` ClusterIssuer and `linkerd-trust-anchor` Certificate/Issuer. Issue the `linkerd-identity-issuer` directly from PCA:

```yaml
issuerRef:
  name: aws-pca-issuer
  group: awspca.cert-manager.io
  kind: AWSPCAClusterIssuer
```

Pass the PCA root certificate (not a cert-manager secret) as the trust anchor to Linkerd:

```bash
aws acm-pca get-certificate-authority-certificate \
  --certificate-authority-arn <ca-arn> --region <region> \
  --query 'Certificate' --output text > ca.crt
```

See `setup-linkerd-pca.sh` for the full automated setup.

## Phase 2: Install Linkerd

### 2.1 Install Linkerd CLI

```bash
brew install linkerd
```

### 2.2 Install Gateway API CRDs (required by Linkerd)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

### 2.3 Pre-flight check

```bash
linkerd check --pre
```

### 2.4 Install Linkerd via Helm

```bash
helm repo add linkerd-edge https://helm.linkerd.io/edge
helm repo update

# Install CRDs
helm install linkerd-crds linkerd-edge/linkerd-crds -n linkerd

# Install control plane
helm install linkerd-control-plane linkerd-edge/linkerd-control-plane \
  -n linkerd \
  --set-file identityTrustAnchorsPEM=ca.crt \
  --set identity.issuer.scheme=kubernetes.io/tls
```

Note: `--set identity.issuer.scheme=kubernetes.io/tls` tells Linkerd to read the issuer cert from the `linkerd-identity-issuer` Kubernetes secret (managed by cert-manager) instead of expecting it inline.

### 2.5 Validate installation

```bash
linkerd check
```

## Phase 3: Mesh the Demo Services

### 3.1 Enable sidecar injection on both namespaces

```bash
kubectl annotate ns service-a-ns linkerd.io/inject=enabled
kubectl annotate ns service-b-ns linkerd.io/inject=enabled
```

### 3.2 Restart deployments to trigger injection

```bash
kubectl rollout restart deployment/service-a-deployment -n service-a-ns
kubectl rollout restart deployment/service-b-deployment -n service-b-ns
```

### 3.3 Verify sidecars are injected

```bash
kubectl get pods -n service-a-ns -o jsonpath='{.items[*].spec.containers[*].name}'
# Should show: server linkerd-proxy

kubectl get pods -n service-b-ns -o jsonpath='{.items[*].spec.containers[*].name}'
# Should show: server linkerd-proxy
```

### 3.4 Verify mTLS is active

```bash
# Check that traffic between services is mTLS
linkerd diagnostics proxy-metrics -n service-a-ns deploy/service-a-deployment | grep tls

# Or install the viz extension for a dashboard view (see Phase 3.5 below)
linkerd viz edges -n service-a-ns
```

### 3.5 Install Linkerd Viz (Observability Dashboard)

The viz extension provides a web dashboard showing live traffic topology, success rates, latency, and mTLS status between services.

```bash
linkerd viz install | kubectl apply -f -
linkerd viz check
```

View mTLS edges and traffic stats from the CLI:

```bash
# Show which connections are mTLS-secured
linkerd viz edges -n service-a-ns
linkerd viz edges -n service-b-ns

# Show per-deployment traffic stats (success rate, RPS, latency)
linkerd viz stat deploy -n service-a-ns
linkerd viz stat deploy -n service-b-ns
```

Launch the web dashboard:

```bash
linkerd viz dashboard
```

This opens a browser with:
- Live topology map of services
- Per-service success rate, request rate, and latency (p50/p95/p99)
- mTLS status (secured vs unsecured) between services

## Phase 3.6: Validate mTLS

### CLI Validation

Generate some traffic and check the edges:

```bash
# Generate traffic
kubectl run curl-test --image=curlimages/curl --rm --restart=Never -n default -- curl -s --max-time 10 service-a.service-a-ns:8080

# Check mTLS edges
linkerd viz edges deploy --all-namespaces | grep -E 'SRC|service-a|service-b'
```

The `SECURED` column shows `√` for mTLS-encrypted connections:

```
SRC                    DST                    SECURED
service-a-deployment → service-b-deployment   √
```

### Wire-Level Validation with tcpdump

For definitive proof, attach a debug container to the service-b pod and capture network traffic. Inside the service-b pod, two conversations happen:

```
External (from service-a pod) ──[mTLS encrypted]──▶ linkerd-proxy
                                                         │ decrypts
                                                         ▼
                                                    service-b app (localhost:8080, plain HTTP)
```

**Capture external traffic (mTLS encrypted):**

```bash
kubectl debug -it <service-b-pod> -n service-b-ns --image=nicolaka/netshoot -- tcpdump -i any -A 'not host 127.0.0.1' -c 50
```

This filters out localhost and shows only inter-pod traffic. You'll see encrypted binary gibberish - no readable HTTP text.

**Capture localhost traffic (decrypted):**

```bash
kubectl debug -it <service-b-pod> -n service-b-ns --image=nicolaka/netshoot -- tcpdump -i any -A port 8080 -c 50
```

This captures the linkerd-proxy → service-b app leg on localhost. You'll see plain HTTP text like `GET / HTTP/1.1` and `Hello from service-b`.

In both cases, trigger a request from another terminal:

```bash
kubectl run curl-test --image=curlimages/curl --rm --restart=Never -n default -- curl -s --max-time 10 service-a.service-a-ns:8080
```

The contrast proves mTLS: external traffic is encrypted, while internal localhost traffic (after the proxy decrypts) is plain HTTP.

## Phase 4: Telepresence + mTLS Demo

This demonstrates that Telepresence works alongside Linkerd mTLS without any special configuration, thanks to Linkerd's PERMISSIVE mode.

### 4.1 Verify service-a still works through the mesh

```bash
# From a pod in the cluster or via telepresence connect
curl service-a.service-a-ns:8080
# Response: {"message":"Hello from service-b! and Hello from service-a!"}
```

### 4.2 Global intercept with mTLS

```bash
telepresence connect -n service-a-ns
telepresence intercept service-a-deployment --port 8080:8080
```

In a separate terminal:

```bash
node local.js
```

Test:

```bash
curl service-a.service-a-ns:8080
# Response: {"message":"Hello from service-b! and Hello from local service-a!"}
```

This proves:
- Telepresence intercept works even though the mesh is active
- The local service can call service-b through the mesh (Linkerd accepts plain HTTP in PERMISSIVE mode)

```bash
telepresence leave service-a-deployment
```

### 4.3 Header-based intercept with mTLS

```bash
telepresence intercept service-a-deployment --port 8080:8080 --http-header x-dev=local
```

Test with header - hits local:

```bash
curl -H "x-dev: local" http://service-a.service-a-ns:8080
# Response: {"message":"Hello from service-b! and Hello from local service-a!"}
```

Test without header - hits in-cluster (through mTLS mesh):

```bash
curl http://service-a.service-a-ns:8080
# Response: {"message":"Hello from service-b! and Hello from service-a!"}
```

### 4.4 Cleanup

```bash
telepresence leave service-a-deployment
telepresence quit -s
```

## Design Decisions

1. **cert-manager in-cluster CA** - cert-manager is already installed. Using the self-signed bootstrap approach avoids local cert generation and is fully automated. For production, swap to AWS Private CA using `aws-privateca-issuer` - see [Production Alternative: AWS Private CA](#production-alternative-aws-private-ca). Note: AWS PCA requires `GENERAL_PURPOSE` mode (~$400/month) for Linkerd since the identity issuer is a long-lived CA cert. The chain is also simplified to 2 levels (PCA as trust anchor) due to PCA's `pathlen:0` constraint on issued CA certs.

2. **Linkerd edge releases** - Since February 2024, the Linkerd open source project only produces edge releases. Stable releases (e.g., 2.19) are announced as version milestones but the actual artifacts are edge releases (e.g., `edge-25.10.7`). Vendor-provided stable releases (with semantic versioning and backported fixes) are available through Buoyant Enterprise. For this demo, edge releases are the standard OSS path.

3. **PERMISSIVE mTLS** - Linkerd's default mode. It accepts both mTLS (from meshed pods) and plain HTTP (from unmeshed sources like Telepresence). This is the recommended approach for dev environments per both Linkerd and Telepresence documentation. In production, use STRICT mode and separate dev/prod namespaces.

4. **Namespace-level injection** - Annotating the namespace rather than individual deployments. Simpler and ensures any new deployments in the namespace are automatically meshed.

## Uninstalling Linkerd

To remove Linkerd and revert to the original plain HTTP setup:

```bash
# Remove namespace annotations
kubectl annotate ns service-a-ns linkerd.io/inject-
kubectl annotate ns service-b-ns linkerd.io/inject-

# Restart deployments to remove sidecars
kubectl rollout restart deployment/service-a-deployment -n service-a-ns
kubectl rollout restart deployment/service-b-deployment -n service-b-ns

# Uninstall Linkerd
linkerd viz uninstall | kubectl delete -f -
helm uninstall linkerd-control-plane -n linkerd
helm uninstall linkerd-crds -n linkerd

# Remove cert-manager resources
kubectl delete -f linkerd-certs.yaml
kubectl delete ns linkerd
```
