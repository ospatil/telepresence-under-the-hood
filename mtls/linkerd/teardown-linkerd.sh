#!/usr/bin/env bash
#
# Teardown Linkerd + self-signed cert-manager bootstrap
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0

Tears down Linkerd + self-signed setup. Restores service-a/b to unmeshed state.

Example:
  $0
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

CERT_MANAGER_NS="cert-manager"
LINKERD_NS="linkerd"

echo "=== Removing mesh from namespaces ==="
kubectl annotate ns service-a-ns linkerd.io/inject- 2>/dev/null || true
kubectl annotate ns service-b-ns linkerd.io/inject- 2>/dev/null || true
kubectl rollout restart deployment/service-a-deployment -n service-a-ns 2>/dev/null || true
kubectl rollout restart deployment/service-b-deployment -n service-b-ns 2>/dev/null || true

echo "=== Removing Linkerd ==="
linkerd viz uninstall 2>/dev/null | kubectl delete -f - 2>/dev/null || true
helm delete linkerd-control-plane -n "$LINKERD_NS" 2>/dev/null || true
helm delete linkerd-crds -n "$LINKERD_NS" 2>/dev/null || true

echo "=== Removing Linkerd certificates ==="
kubectl delete -f linkerd-certs.yaml 2>/dev/null || true
kubectl delete ns "$LINKERD_NS" --ignore-not-found

echo "=== Removing cert-manager ==="
helm delete cert-manager -n "$CERT_MANAGER_NS" 2>/dev/null || true
kubectl delete ns "$CERT_MANAGER_NS" --ignore-not-found

echo "=== Teardown complete ==="
