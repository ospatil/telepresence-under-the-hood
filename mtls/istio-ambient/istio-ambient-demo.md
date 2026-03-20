# East-West mTLS with Istio Ambient + Telepresence Demo

This demonstrates automatic mTLS between services using Istio Ambient mode (sidecar-less), then shows that Telepresence intercepts still work.

## Prerequisites

- Existing cluster with Linkerd demo running (service-a-ns, service-b-ns)
- Telepresence client and traffic manager (v2.25+)
- Helm 3.6+

## Architecture

Istio Ambient splits the data plane into two layers:

```
Layer 1 - ztunnel (always on, L4):
  DaemonSet, one per node. Handles mTLS encryption and L4 auth.
  No sidecars, no pod changes.

  service-c pod ──▶ ztunnel (Node 1) ══mTLS══▶ ztunnel (Node 2) ──▶ service-d pod

Layer 2 - waypoint proxy (optional, L7):
  Standalone Envoy pod, deployed per namespace or per service.
  Only needed for HTTP routing, retries, L7 auth, traffic splitting, etc.
  NOT needed for this demo.
```

Key difference from Linkerd: no sidecar is injected into your pods. The ztunnel runs at the node level and transparently intercepts traffic for enrolled namespaces.

## Phase 1: Install Istio Ambient

### 1.1 Add Istio Helm repo

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
```

### 1.2 Install Istio base CRDs

```bash
helm install istio-base istio/base -n istio-system --create-namespace --wait
```

### 1.3 Install istiod control plane (ambient profile)

```bash
helm install istiod istio/istiod -n istio-system --set profile=ambient --wait
```

### 1.4 Install CNI node agent

The CNI agent configures traffic redirection between pods and ztunnel.

```bash
helm install istio-cni istio/cni -n istio-system --set profile=ambient --wait
```

### 1.5 Install ztunnel DaemonSet

```bash
helm install ztunnel istio/ztunnel -n istio-system --wait
```

### 1.6 Verify installation

```bash
helm ls -n istio-system
kubectl get pods -n istio-system
# Should see: istiod, istio-cni-node (per node), ztunnel (per node)
```

### Production Alternative: AWS Private CA

For production, you can replace istiod's built-in CA with AWS Private CA. Unlike Linkerd (which already uses cert-manager), Istio manages its own certs internally, so the integration requires [istio-csr](https://github.com/cert-manager/istio-csr) as a bridge between istiod and cert-manager.

Install the components:

```bash
# cert-manager (if not already installed)
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true

# AWS PCA issuer plugin
helm repo add awspca https://cert-manager.github.io/aws-privateca-issuer
helm install aws-pca-issuer awspca/aws-privateca-issuer -n cert-manager

# istio-csr - bridges istiod cert requests to cert-manager
# caTrustedNodeAccounts enables ambient mode (ztunnel cert requests)
helm repo add jetstack https://charts.jetstack.io
helm install istio-csr jetstack/cert-manager-istio-csr -n cert-manager \
  --set app.certmanager.issuer.name=aws-pca-issuer \
  --set app.certmanager.issuer.kind=AWSPCAClusterIssuer \
  --set app.certmanager.issuer.group=awspca.cert-manager.io \
  --set app.server.caTrustedNodeAccounts=istio-system/ztunnel
```

Create the AWS PCA issuer:

```yaml
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAClusterIssuer
metadata:
  name: aws-pca-issuer
spec:
  arn: arn:aws:acm-pca:<region>:<account>:certificate-authority/<ca-id>
  region: <region>
```

Then install istiod and ztunnel with external CA configuration:

```bash
helm install istiod istio/istiod -n istio-system \
  --set profile=ambient \
  --set pilot.env.ENABLE_CA_SERVER=false

# ztunnel must point at istio-csr for cert signing (not istiod)
helm install ztunnel istio/ztunnel -n istio-system \
  --set caAddress=cert-manager-istio-csr.cert-manager.svc:443
```

`ENABLE_CA_SERVER=false` disables istiod's built-in CA. The ztunnel `caAddress` directs workload cert requests to `istio-csr` (which forwards to cert-manager → AWS PCA). `caTrustedNodeAccounts` allows ztunnel's service account to request certs on behalf of workloads on its node. See `setup-istio-pca.sh` for the full automated setup.

## Phase 2: Deploy Istio Demo Services

### 2.1 Create namespaces and enroll in ambient mesh

```bash
kubectl create ns service-c-ns
kubectl create ns service-d-ns
kubectl label ns service-c-ns istio.io/dataplane-mode=ambient
kubectl label ns service-d-ns istio.io/dataplane-mode=ambient
```

Note: unlike Linkerd, no pod restart is needed. Enrollment is instant.

### 2.2 Deploy service-d (clone of service-b)

```bash
kubectl apply -f d-manifest.yaml
```

### 2.3 Deploy service-c (clone of service-a, calls service-d)

```bash
kubectl apply -f c-manifest.yaml
```

### 2.4 Verify services are running

```bash
kubectl get pods -n service-c-ns
kubectl get pods -n service-d-ns
# Pods should be running with NO sidecars (1/1 READY, not 2/2)
```

### 2.5 Test the service chain

```bash
kubectl run curl-test --image=curlimages/curl --rm --restart=Never -n default \
  -- curl -s --max-time 10 service-c.service-c-ns:8080
# Expected: {"message":"Hello from service-d! and Hello from service-c!","path":"/"}
```

## Phase 3: Validate mTLS

### 3.1 Check ztunnel workload enrollment

```bash
istioctl ztunnel-config workloads | grep -E 'service-c|service-d'
# Should show PROTOCOL=HBONE for both, confirming they're in the mesh
```

### 3.2 Wire-level validation with tcpdump

Same approach as the Linkerd demo - attach a debug container to the service-d pod:

**Capture external traffic (mTLS encrypted):**

```bash
kubectl debug -it <service-d-pod> -n service-d-ns --image=nicolaka/netshoot \
  -- tcpdump -i any -A 'not host 127.0.0.1' -c 50
```

**Capture localhost traffic (decrypted):**

```bash
kubectl debug -it <service-d-pod> -n service-d-ns --image=nicolaka/netshoot \
  -- tcpdump -i any -A port 8080 -c 50
```

Trigger a request from another terminal:

```bash
kubectl run curl-test --image=curlimages/curl --rm --restart=Never -n default \
  -- curl -s --max-time 10 service-c.service-c-ns:8080
```

External traffic shows encrypted gibberish; localhost traffic shows plain HTTP. Same proof as Linkerd, but without any sidecars.

## Phase 4: Telepresence + Istio Ambient mTLS Demo

Istio Ambient defaults to PERMISSIVE mTLS - it accepts both mTLS (from meshed pods) and plain HTTP (from unmeshed sources like Telepresence).

### 4.1 Connect and verify

```bash
telepresence connect -n service-c-ns
curl service-c.service-c-ns:8080
# Expected: {"message":"Hello from service-d! and Hello from service-c!","path":"/"}
```

### 4.2 Global intercept

```bash
telepresence intercept service-c-deployment --port 8080:8080
```

In a separate terminal, start the local service:

```bash
node local-c.js
```

Test:

```bash
curl service-c.service-c-ns:8080
# Expected: {"message":"Hello from service-d! and Hello from local service-c!","path":"/"}
```

```bash
telepresence leave service-c-deployment
```

### 4.3 Header-based intercept

```bash
telepresence intercept service-c-deployment --port 8080:8080 --http-header x-dev=local
```

Test with header - hits local:

```bash
curl -H "x-dev: local" http://service-c.service-c-ns:8080
# Expected: {"message":"Hello from service-d! and Hello from local service-c!","path":"/"}
```

Test without header - hits in-cluster (through mTLS mesh):

```bash
curl http://service-c.service-c-ns:8080
# Expected: {"message":"Hello from service-d! and Hello from service-c!","path":"/"}
```

### 4.4 Cleanup

```bash
telepresence leave service-c-deployment
telepresence quit -s
```

## Comparison: Linkerd vs Istio Ambient

| Aspect | Linkerd | Istio Ambient |
|---|---|---|
| Data plane | Sidecar per pod (~20MB each) | ztunnel per node (~30MB each) |
| Pod changes | Sidecar injected, pod restart required | No sidecar, no pod restart |
| Namespace enrollment | Annotation + restart | Label (instant) |
| mTLS default | PERMISSIVE | PERMISSIVE |
| L7 features | Built into sidecar (always available) | Requires waypoint proxy (per namespace, on demand) |
| Control plane size | ~250MB | ~1GB (istiod) |
| Cert management | External (cert-manager) | Built-in (istiod manages certs) |
| Telepresence compat | Works in PERMISSIVE mode | Works in PERMISSIVE mode |
| Observability | linkerd-viz (dashboard + CLI) | Kiali, Prometheus, Grafana |

## Design Decisions

1. **No waypoint proxy** - We only need mTLS (L4). Waypoint proxies are for L7 features (HTTP routing, retries, auth policies) and add unnecessary complexity for this demo.

2. **Istio manages its own certs** - Unlike Linkerd which requires external cert management (cert-manager), istiod has a built-in CA that automatically issues and rotates workload certificates. No additional cert setup needed. For production, you can swap to AWS Private CA via `istio-csr` + `aws-privateca-issuer` - see [Production Alternative: AWS Private CA](#production-alternative-aws-private-ca).

3. **PERMISSIVE mTLS** - Default mode, same as Linkerd. Accepts both mTLS and plain HTTP, enabling Telepresence compatibility without configuration changes.

4. **Separate namespaces** - Istio Ambient services run in their own namespaces (`service-c-ns`, `service-d-ns`).

## Uninstalling Istio Ambient

```bash
# Remove namespace labels
kubectl label ns service-c-ns istio.io/dataplane-mode-
kubectl label ns service-d-ns istio.io/dataplane-mode-

# Delete demo services
kubectl delete -f c-manifest.yaml
kubectl delete -f d-manifest.yaml
kubectl delete ns service-c-ns service-d-ns

# Uninstall Istio components (order matters)
helm delete ztunnel -n istio-system
helm delete istio-cni -n istio-system
helm delete istiod -n istio-system
helm delete istio-base -n istio-system

# Optional: remove Istio CRDs
kubectl get crd -oname | grep 'istio.io' | xargs kubectl delete

kubectl delete namespace istio-system
```
