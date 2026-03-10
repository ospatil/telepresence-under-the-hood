#!/usr/bin/env bash
#
# Initial setup: deploy demo services and install Telepresence traffic manager
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0

Deploys the base demo services (service-a, service-b) and installs the
Telepresence traffic manager. Run from the repo root.

Prerequisites:
  - EKS cluster running and kubectl connected (via SSM port-forward)
  - Telepresence client installed (brew install telepresenceio/telepresence/telepresence-oss)

Example:
  $0
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Creating namespaces ==="
kubectl create ns service-a-ns --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns service-b-ns --dry-run=client -o yaml | kubectl apply -f -

echo "=== Deploying services ==="
kubectl apply -f "$SCRIPT_DIR/services/b-manifest.yaml"
kubectl apply -f "$SCRIPT_DIR/services/a-manifest.yaml"

echo "Waiting for pods..."
kubectl wait --for=condition=Ready pod -l app=service-b -n service-b-ns --timeout=120s
kubectl wait --for=condition=Ready pod -l app=service-a -n service-a-ns --timeout=120s

echo "=== Installing Telepresence traffic manager ==="
telepresence helm install 2>/dev/null || telepresence helm upgrade 2>/dev/null || echo "Traffic manager already up to date."

echo "=== Validation ==="
echo "Testing service chain..."
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n default -- \
  curl -s --max-time 10 service-a.service-a-ns:8080

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  telepresence connect -n service-a-ns"
echo "  curl service-a.service-a-ns:8080"
echo "  telepresence intercept service-a-deployment --port 8080:8080"
