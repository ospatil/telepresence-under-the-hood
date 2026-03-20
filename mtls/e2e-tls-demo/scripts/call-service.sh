#!/usr/bin/env bash
#
# Call in-cluster services via Telepresence connect mode
#
# Usage: ./call-service.sh [greeting|quote]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CERTS_DIR="$PROJECT_DIR/.certs"

# Load .env file if it exists
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  source "$PROJECT_DIR/.env"
  set +a
fi

AWS_REGION="${AWS_REGION:-ca-central-1}"

# Download CA cert from PCA if not present
ensure_ca_cert() {
  local service=$1
  local cert_path="$CERTS_DIR/$service-service/ca.crt"

  mkdir -p "$CERTS_DIR/$service-service"

  if [[ ! -s "$cert_path" ]]; then
    if [[ -z "${ROOT_CA_ARN:-}" ]]; then
      echo "Error: ROOT_CA_ARN is not set. Set it in .env or export it." >&2
      exit 1
    fi
    echo "Downloading CA cert from PCA..." >&2
    aws acm-pca get-certificate-authority-certificate \
      --certificate-authority-arn "$ROOT_CA_ARN" \
      --region "$AWS_REGION" \
      --query 'Certificate' --output text > "$cert_path"
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

# Wait for Telepresence DNS to resolve a cluster service
wait_for_dns() {
  local host=$1
  local retries=0
  echo "Waiting for cluster DNS..."
  while ! python3 -c "import socket; socket.getaddrinfo('$host', None)" &>/dev/null && (( retries < 10 )); do
    sleep 1
    ((retries++))
  done
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
wait_for_dns "$SERVICE.$NS.svc.cluster.local"
CA_CERT=$(ensure_ca_cert "$TARGET")

URL="https://$SERVICE.$NS.svc.cluster.local:8443$ENDPOINT"

echo ""
echo "=== Calling $SERVICE ==="
echo "URL: $URL"
echo ""

curl -s --cacert "$CA_CERT" "$URL" | jq . 2>/dev/null || curl -s --cacert "$CA_CERT" "$URL"

echo ""
