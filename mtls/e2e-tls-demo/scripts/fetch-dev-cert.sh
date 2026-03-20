#!/usr/bin/env bash
#
# Fetch a dev certificate from Secrets Manager to local .certs/ directory.
#
# Usage: ./fetch-dev-cert.sh <service-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

SERVICE_NAME="${1:-}"
[[ -z "$SERVICE_NAME" ]] && echo "Usage: $0 <service-name>" && exit 1

AWS_REGION="${AWS_REGION:-ca-central-1}"
SECRET_NAME="e2e-tls-demo/dev-certs/$SERVICE_NAME"
CERTS_DIR="$PROJECT_DIR/.certs/$SERVICE_NAME"

mkdir -p "$CERTS_DIR"

echo "Fetching dev cert for $SERVICE_NAME from Secrets Manager..."
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query 'SecretString' --output text 2>&1)

if [[ $? -ne 0 ]]; then
  echo "Error: cert not found. Request one first:"
  echo "  ./request-dev-cert.sh $SERVICE_NAME"
  exit 1
fi

echo "$SECRET" | jq -r '."tls.crt"' > "$CERTS_DIR/tls.crt"
echo "$SECRET" | jq -r '."tls.key"' > "$CERTS_DIR/tls.key"
echo "$SECRET" | jq -r '."ca.crt"' > "$CERTS_DIR/ca.crt"
chmod 600 "$CERTS_DIR/tls.key"

EXPIRY=$(openssl x509 -noout -enddate -in "$CERTS_DIR/tls.crt" | cut -d= -f2)

echo ""
echo "=== Certificate fetched ==="
echo "Files:"
echo "  $CERTS_DIR/tls.crt  (certificate)"
echo "  $CERTS_DIR/tls.key  (private key)"
echo "  $CERTS_DIR/ca.crt   (CA certificate)"
echo "Expires: $EXPIRY"
echo ""
echo "Use with run-local.sh:"
echo "  ./run-local.sh $SERVICE_NAME"
