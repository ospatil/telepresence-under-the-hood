#!/usr/bin/env bash
#
# Inspect TLS certificates — local dev certs and in-cluster pod certs.
#
# Usage:
#   ./inspect-cert.sh local <service-name>    # inspect local dev cert
#   ./inspect-cert.sh pod <service-name>      # inspect cert inside the pod
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

MODE="${1:-}"
SERVICE_NAME="${2:-}"

if [[ -z "$MODE" || -z "$SERVICE_NAME" ]]; then
  echo "Usage:"
  echo "  $0 local <service-name>   # inspect local dev cert in .certs/"
  echo "  $0 pod <service-name>     # inspect cert inside the running pod"
  exit 1
fi

NAMESPACE="${SERVICE_NAME}-ns"

print_cert_info() {
  local cert_pem="$1"
  local label="$2"

  echo "=== $label ==="
  echo "$cert_pem" | openssl x509 -noout \
    -subject -issuer -dates -ext subjectAltName 2>/dev/null

  # Show server/client capability
  local ssl_client ssl_server
  ssl_client=$(echo "$cert_pem" | openssl x509 -noout -purpose 2>/dev/null | grep "^SSL client :" | awk '{print $4}')
  ssl_server=$(echo "$cert_pem" | openssl x509 -noout -purpose 2>/dev/null | grep "^SSL server :" | awk '{print $4}')
  if [[ -n "$ssl_client" || -n "$ssl_server" ]]; then
    echo "SSL server: ${ssl_server:-N/A}, SSL client: ${ssl_client:-N/A}"
  fi

  # Check expiry
  if echo "$cert_pem" | openssl x509 -checkend 0 -noout 2>/dev/null; then
    local days_left
    days_left=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    echo "Status: VALID (expires $days_left)"
  else
    echo "Status: EXPIRED"
  fi
  echo ""
}

case "$MODE" in
  local)
    CERTS_DIR="$PROJECT_DIR/.certs/$SERVICE_NAME"
    if [[ ! -f "$CERTS_DIR/tls.crt" ]]; then
      echo "No local cert found at $CERTS_DIR/tls.crt"
      echo "Fetch one: ./fetch-dev-cert.sh $SERVICE_NAME"
      exit 1
    fi
    print_cert_info "$(cat "$CERTS_DIR/tls.crt")" "Local dev cert ($SERVICE_NAME)"
    print_cert_info "$(cat "$CERTS_DIR/ca.crt")" "CA cert (truststore)"
    ;;

  pod)
    POD=$(kubectl get pod -n "$NAMESPACE" -l "app=$SERVICE_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$POD" ]]; then
      echo "No pod found for $SERVICE_NAME in $NAMESPACE"
      exit 1
    fi
    echo "Pod: $POD"
    echo ""
    print_cert_info "$(kubectl exec -n "$NAMESPACE" "$POD" -- cat /certs/tls.crt)" "Pod cert ($SERVICE_NAME)"
    print_cert_info "$(kubectl exec -n "$NAMESPACE" "$POD" -- cat /certs/ca.crt)" "CA cert (truststore)"
    ;;

  *)
    echo "Unknown mode: $MODE"
    echo "Use 'local' or 'pod'"
    exit 1
    ;;
esac
