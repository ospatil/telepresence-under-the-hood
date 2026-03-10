#!/usr/bin/env bash
#
# Teardown Istio Ambient + built-in CA
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0

Tears down Istio Ambient + built-in CA setup.

Example:
  $0
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

ISTIO_NS="istio-system"

echo "=== Removing services ==="
kubectl label ns service-c-ns istio.io/dataplane-mode- 2>/dev/null || true
kubectl label ns service-d-ns istio.io/dataplane-mode- 2>/dev/null || true
kubectl delete -f ../../services/c-manifest.yaml --ignore-not-found
kubectl delete -f ../../services/d-manifest.yaml --ignore-not-found
kubectl delete ns service-c-ns service-d-ns --ignore-not-found

echo "=== Removing Istio ==="
helm delete ztunnel -n "$ISTIO_NS" 2>/dev/null || true
helm delete istio-cni -n "$ISTIO_NS" 2>/dev/null || true
helm delete istiod -n "$ISTIO_NS" 2>/dev/null || true
helm delete istio-base -n "$ISTIO_NS" 2>/dev/null || true
kubectl get crd -oname | grep 'istio.io' | xargs kubectl delete 2>/dev/null || true
kubectl delete ns "$ISTIO_NS" --ignore-not-found

echo "=== Teardown complete ==="
