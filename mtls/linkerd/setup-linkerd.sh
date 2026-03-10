#!/usr/bin/env bash
#
# Linkerd mTLS + self-signed cert-manager bootstrap
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0

Sets up Linkerd mTLS with self-signed cert-manager bootstrap.
Uses service-a and service-b (must already be deployed).

Prerequisites:
  - EKS cluster "auto-mode-private-access" running in ca-central-1
  - kubectl configured and connected (via SSM port-forward)
  - helm 3.6+, linkerd CLI
  - service-a and service-b deployed (services/a-manifest.yaml, services/b-manifest.yaml)

Example:
  $0
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

CERT_MANAGER_NS="cert-manager"
LINKERD_NS="linkerd"

# ── Phase 1: cert-manager ────────────────────────────────────────────────────

echo "=== Phase 1: cert-manager ==="

helm repo add jetstack https://charts.jetstack.io
helm repo update

if helm status cert-manager -n "$CERT_MANAGER_NS" &>/dev/null; then
  echo "cert-manager already installed, skipping."
else
  echo "Installing cert-manager..."
  helm install cert-manager jetstack/cert-manager \
    -n "$CERT_MANAGER_NS" --create-namespace \
    --set crds.enabled=true --wait
fi

# ── Phase 2: Linkerd Certificate Infrastructure ──────────────────────────────

echo "=== Phase 2: Linkerd Certificate Infrastructure (self-signed) ==="

kubectl create ns "$LINKERD_NS" --dry-run=client -o yaml | kubectl apply -f -

echo "Applying linkerd-certs.yaml..."
kubectl apply -f linkerd-certs.yaml

echo "Waiting for certificates to be ready..."
kubectl wait --for=condition=Ready certificate/linkerd-trust-anchor -n "$LINKERD_NS" --timeout=120s
kubectl wait --for=condition=Ready certificate/linkerd-identity-issuer -n "$LINKERD_NS" --timeout=120s

echo "Extracting trust anchor..."
kubectl get secret linkerd-trust-anchor -n "$LINKERD_NS" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/linkerd-ca.crt

# ── Phase 3: Install Linkerd ─────────────────────────────────────────────────

echo "=== Phase 3: Install Linkerd ==="

echo "Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

helm repo add linkerd-edge https://helm.linkerd.io/edge
helm repo update

echo "Installing Linkerd CRDs..."
helm install linkerd-crds linkerd-edge/linkerd-crds -n "$LINKERD_NS" --wait

echo "Installing Linkerd control plane..."
helm install linkerd-control-plane linkerd-edge/linkerd-control-plane \
  -n "$LINKERD_NS" \
  --set-file identityTrustAnchorsPEM=/tmp/linkerd-ca.crt \
  --set identity.issuer.scheme=kubernetes.io/tls \
  --wait

echo "Validating Linkerd installation..."
linkerd check || echo "WARNING: linkerd check reported issues"

# ── Phase 4: Mesh the Services ───────────────────────────────────────────────

echo "=== Phase 4: Mesh service-a and service-b ==="

kubectl annotate ns service-a-ns linkerd.io/inject=enabled --overwrite
kubectl annotate ns service-b-ns linkerd.io/inject=enabled --overwrite

kubectl rollout restart deployment/service-a-deployment -n service-a-ns
kubectl rollout restart deployment/service-b-deployment -n service-b-ns

kubectl rollout status deployment/service-a-deployment -n service-a-ns --timeout=120s
kubectl rollout status deployment/service-b-deployment -n service-b-ns --timeout=120s

# ── Phase 5: Validation ──────────────────────────────────────────────────────

echo "=== Phase 5: Validation ==="

echo "Testing service chain..."
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n default -- \
  curl -s --max-time 10 service-a.service-a-ns:8080

echo ""
echo "Installing linkerd-viz..."
linkerd viz install | kubectl apply -f -
sleep 10
linkerd viz edges deploy -n service-a-ns 2>/dev/null || echo "(viz may need a moment to collect data)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  - Validate mTLS with tcpdump (see mtls-demo.md Phase 3.6)"
echo "  - Test Telepresence intercepts (see mtls-demo.md Phase 4)"
