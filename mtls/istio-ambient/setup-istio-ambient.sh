#!/usr/bin/env bash
#
# Istio Ambient mTLS + built-in CA (istiod manages certs)
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0

Sets up Istio Ambient mTLS with istiod's built-in CA.
Deploys service-c and service-d in ambient mesh.

Prerequisites:
  - EKS cluster "auto-mode-private-access" running in ca-central-1
  - kubectl configured and connected (via SSM port-forward)
  - helm 3.6+, istioctl

Example:
  $0
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

ISTIO_NS="istio-system"

# ── Phase 1: Install Istio Ambient ────────────────────────────────────────────

echo "=== Phase 1: Install Istio Ambient ==="

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

echo "Installing Istio base CRDs..."
helm install istio-base istio/base -n "$ISTIO_NS" --create-namespace --wait

echo "Installing istiod (built-in CA)..."
helm install istiod istio/istiod -n "$ISTIO_NS" --set profile=ambient --wait

echo "Installing istio-cni..."
helm install istio-cni istio/cni -n "$ISTIO_NS" --set profile=ambient --wait

echo "Installing ztunnel..."
helm install ztunnel istio/ztunnel -n "$ISTIO_NS" --wait

echo "Verifying installation..."
kubectl get pods -n "$ISTIO_NS"

# ── Phase 2: Deploy Services ─────────────────────────────────────────────────

echo "=== Phase 2: Deploy services ==="

kubectl create ns service-c-ns --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns service-d-ns --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns service-c-ns istio.io/dataplane-mode=ambient --overwrite
kubectl label ns service-d-ns istio.io/dataplane-mode=ambient --overwrite

kubectl apply -f ../../services/d-manifest.yaml
kubectl apply -f ../../services/c-manifest.yaml

kubectl wait --for=condition=Ready pod -l app=service-d -n service-d-ns --timeout=120s
kubectl wait --for=condition=Ready pod -l app=service-c -n service-c-ns --timeout=120s

# ── Phase 3: Validation ──────────────────────────────────────────────────────

echo "=== Phase 3: Validation ==="

echo "Checking ztunnel enrollment..."
istioctl ztunnel-config workloads | grep -E 'service-c|service-d' || echo "WARNING: services not enrolled yet"

echo "Testing service chain..."
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n default -- \
  curl -s --max-time 10 service-c.service-c-ns:8080

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  - Validate mTLS with tcpdump (see istio-ambient-demo.md Phase 3.2)"
echo "  - Test Telepresence intercepts (see istio-ambient-demo.md Phase 4)"
