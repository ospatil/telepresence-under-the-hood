#!/usr/bin/env bash
#
# Request a dev certificate for a service via Lambda.
# The Lambda issues the cert from the dev CA and stores it in Secrets Manager.
# No private keys are generated locally.
#
# Usage: ./request-dev-cert.sh <service-name> [--force]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

SERVICE_NAME="${1:-}"
FORCE="${2:-}"
[[ -z "$SERVICE_NAME" ]] && echo "Usage: $0 <service-name> [--force]" && exit 1

AWS_REGION="${AWS_REGION:-ca-central-1}"
LAMBDA_NAME="e2e-tls-demo-issue-dev-cert"

PAYLOAD=$(jq -n --arg svc "$SERVICE_NAME" --argjson force "$([ "$FORCE" = "--force" ] && echo true || echo false)" \
  '{service_name: $svc, force: $force}')

echo "Requesting dev cert for $SERVICE_NAME..."
OUTFILE=$(mktemp)
aws lambda invoke \
  --function-name "$LAMBDA_NAME" \
  --payload "$PAYLOAD" \
  --region "$AWS_REGION" \
  --cli-binary-format raw-in-base64-out \
  "$OUTFILE" > /dev/null 2>&1

STATUS=$(jq -r '.statusCode' "$OUTFILE")
BODY=$(jq -r '.body' "$OUTFILE")
rm -f "$OUTFILE"

if [[ "$STATUS" == "200" ]]; then
  echo "$BODY"
  echo ""
  echo "Fetch the cert locally with:"
  echo "  ./fetch-dev-cert.sh $SERVICE_NAME"
else
  echo "Error: $BODY"
  exit 1
fi
