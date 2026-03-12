#!/usr/bin/env bash
#
# Run a service locally with cluster TLS certs for Telepresence intercept
#
# Usage: ./run-local.sh <service-name>
#   service-name: greeting-service or quote-service
#
# Note: With CSI driver, certs are only in pod filesystem (no Secrets).
# This script extracts them by exec'ing into the pod.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SERVICE_NAME="${1:-}"
if [[ -z "$SERVICE_NAME" ]]; then
  echo "Usage: $0 <service-name>"
  echo "  service-name: greeting-service or quote-service"
  exit 1
fi

NAMESPACE="${SERVICE_NAME}-ns"
CERTS_DIR="$SCRIPT_DIR/.certs/$SERVICE_NAME"
JAR_PATH="$SCRIPT_DIR/$SERVICE_NAME/target/$SERVICE_NAME-0.0.1-SNAPSHOT.jar"

# Check JAR exists
if [[ ! -f "$JAR_PATH" ]]; then
  echo "JAR not found: $JAR_PATH"
  echo "Build first: cd $SERVICE_NAME && ./mvnw package -DskipTests"
  exit 1
fi

# Create certs directory
mkdir -p "$CERTS_DIR"

echo "=== Extracting certificates from pod (CSI driver) ==="
POD_NAME=$(kubectl get pod -n "$NAMESPACE" -l app="$SERVICE_NAME" -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD_NAME"

kubectl exec -n "$NAMESPACE" "$POD_NAME" -- cat /certs/tls.crt > "$CERTS_DIR/tls.crt"
kubectl exec -n "$NAMESPACE" "$POD_NAME" -- cat /certs/tls.key > "$CERTS_DIR/tls.key"
kubectl exec -n "$NAMESPACE" "$POD_NAME" -- cat /certs/ca.crt > "$CERTS_DIR/ca.crt"

echo "Certificates saved to: $CERTS_DIR"

echo ""
echo "=== Starting $SERVICE_NAME locally ==="
echo "Ports: 8443 (HTTPS), 8080 (HTTP management)"
echo ""
echo "To intercept, run in another terminal:"
echo "  telepresence connect -n $NAMESPACE"
echo "  telepresence intercept $SERVICE_NAME --port 8443:8443"
echo ""
echo "To verify:"
echo "  curl https://greeting.\${DOMAIN}/greeting"
echo "  curl --cacert $CERTS_DIR/ca.crt https://$SERVICE_NAME.$NAMESPACE.svc.cluster.local:8443/greeting"
echo ""
echo "=========================================="
echo "  SERVICE RUNNING LOCALLY - Watch logs below"
echo "=========================================="
echo ""

exec java -jar "$JAR_PATH" \
  --spring.ssl.bundle.pem.server.keystore.certificate="$CERTS_DIR/tls.crt" \
  --spring.ssl.bundle.pem.server.keystore.private-key="$CERTS_DIR/tls.key" \
  --spring.ssl.bundle.pem.server.truststore.certificate="$CERTS_DIR/ca.crt" \
  --spring.ssl.bundle.pem.client.truststore.certificate="$CERTS_DIR/ca.crt" \
  --logging.level.org.springframework.web=DEBUG
