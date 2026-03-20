#!/usr/bin/env bash
#
# Run a service locally with PCA-issued TLS certs for Telepresence intercept.
#
# Usage: ./run-local.sh <service-name>
#   service-name: greeting-service or quote-service
#
# Prerequisites:
#   Run ./request-dev-cert.sh <service-name> then ./fetch-dev-cert.sh <service-name> first.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVICE_NAME="${1:-}"
if [[ -z "$SERVICE_NAME" ]]; then
  echo "Usage: $0 <service-name>"
  echo "  service-name: greeting-service or quote-service"
  exit 1
fi

NAMESPACE="${SERVICE_NAME}-ns"
CERTS_DIR="$PROJECT_DIR/.certs/$SERVICE_NAME"
JAR_PATH="$PROJECT_DIR/$SERVICE_NAME/target/$SERVICE_NAME-0.0.1-SNAPSHOT.jar"

# Check JAR exists
if [[ ! -f "$JAR_PATH" ]]; then
  echo "JAR not found: $JAR_PATH"
  echo "Build first: cd $SERVICE_NAME && ./mvnw package -DskipTests"
  exit 1
fi

# Check certs exist
if [[ ! -s "$CERTS_DIR/tls.crt" || ! -s "$CERTS_DIR/tls.key" || ! -s "$CERTS_DIR/ca.crt" ]]; then
  echo "Certificates not found in $CERTS_DIR"
  echo "Run first:"
  echo "  ./request-dev-cert.sh $SERVICE_NAME"
  echo "  ./fetch-dev-cert.sh $SERVICE_NAME"
  exit 1
fi

# Check cert hasn't expired
if ! openssl x509 -checkend 0 -noout -in "$CERTS_DIR/tls.crt" 2>/dev/null; then
  echo "Certificate has expired. Re-issue:"
  echo "  ./request-dev-cert.sh $SERVICE_NAME && ./fetch-dev-cert.sh $SERVICE_NAME"
  exit 1
fi

EXPIRY=$(openssl x509 -noout -enddate -in "$CERTS_DIR/tls.crt" | cut -d= -f2)

echo ""
echo "=== Starting $SERVICE_NAME locally ==="
echo "Certs:   $CERTS_DIR (expires: $EXPIRY)"
echo "Ports:   8443 (HTTPS), 8080 (HTTP management)"
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
