#!/usr/bin/env bash
#
# Call in-cluster services via Telepresence connect mode
#
# Usage: ./call-service.sh [greeting|quote]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/.certs"

# Extract CA cert if not present
extract_ca_cert() {
  local service=$1
  local ns="${service}-service-ns"
  local cert_path="$CERTS_DIR/$service-service/ca.crt"

  mkdir -p "$CERTS_DIR/$service-service"

  if [[ ! -f "$cert_path" ]]; then
    echo "Extracting CA cert for $service-service..."
    kubectl get secret "$service-service-tls" -n "$ns" \
      -o jsonpath='{.data.ca\.crt}' | base64 -d > "$cert_path"
  fi

  echo "$cert_path"
}

# Check Telepresence connection
check_telepresence() {
  if ! telepresence status 2>/dev/null | grep -q "Connected"; then
    echo "Telepresence not connected. Connecting..."
    telepresence connect
  fi
}

TARGET="${1:-greeting}"

case "$TARGET" in
  greeting)
    SERVICE="greeting-service"
    NS="greeting-service-ns"
    ENDPOINT="/greeting"
    ;;
  quote)
    SERVICE="quote-service"
    NS="quote-service-ns"
    ENDPOINT="/quote"
    ;;
  *)
    echo "Usage: $0 [greeting|quote]"
    exit 1
    ;;
esac

check_telepresence
CA_CERT=$(extract_ca_cert "$TARGET")

URL="https://$SERVICE.$NS.svc.cluster.local:8443$ENDPOINT"

echo ""
echo "=== Calling $SERVICE ==="
echo "URL: $URL"
echo ""

curl -s --cacert "$CA_CERT" "$URL" | jq . 2>/dev/null || curl -s --cacert "$CA_CERT" "$URL"

echo ""
