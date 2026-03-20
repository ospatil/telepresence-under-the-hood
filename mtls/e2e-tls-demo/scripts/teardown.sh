#!/usr/bin/env bash
#
# E2E TLS Demo Teardown
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env file if it exists
if [[ -f "$PROJECT_DIR/.env" ]]; then
  echo "Loading configuration from .env file..."
  set -a
  source "$PROJECT_DIR/.env"
  set +a
fi

usage() {
  cat <<EOF
Usage: $0

Tears down the E2E TLS demo.

Configuration:
  Uses .env file if present, or set environment variables:
    AWS_ACCOUNT_ID, AWS_REGION, DOMAIN, HOSTED_ZONE_ID (from .env)
    ROOT_CA_ARN, CLUSTER_CA_ARN, DEV_CA_ARN, ACM_CERT_ARN (printed by setup.sh on completion)
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage
[[ -z "${AWS_ACCOUNT_ID:-}" ]] && echo "Error: AWS_ACCOUNT_ID is not set." && usage
[[ -z "${ROOT_CA_ARN:-}" ]] && echo "Error: ROOT_CA_ARN is not set." && usage
[[ -z "${CLUSTER_CA_ARN:-}" ]] && echo "Error: CLUSTER_CA_ARN is not set." && usage
[[ -z "${DEV_CA_ARN:-}" ]] && echo "Error: DEV_CA_ARN is not set." && usage
[[ -z "${ACM_CERT_ARN:-}" ]] && echo "Error: ACM_CERT_ARN is not set." && usage
[[ -z "${DOMAIN:-}" ]] && echo "Error: DOMAIN is not set." && usage
[[ -z "${HOSTED_ZONE_ID:-}" ]] && echo "Error: HOSTED_ZONE_ID is not set." && usage

AWS_REGION="${AWS_REGION:-ca-central-1}"
CLUSTER_NAME="auto-mode-private-access"
ROLE_PREFIX="e2e-tls-demo"
CERT_MANAGER_NS="cert-manager"

echo "=== Removing Ingress & Services ==="
kubectl delete ingress greeting-service -n greeting-service-ns 2>/dev/null || true
kubectl delete ns greeting-service-ns quote-service-ns --ignore-not-found

echo "=== Removing external-dns ==="
# Delete Pod Identity association
ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query "associations[?serviceAccount=='external-dns' && namespace=='kube-system'].associationId" --output text 2>/dev/null || true)
[ -n "$ASSOC_ID" ] && aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --region "$AWS_REGION"
helm delete external-dns -n kube-system 2>/dev/null || true

echo "=== Removing AWS PCA Issuer ==="
kubectl delete awspcaclusterissuer aws-pca-issuer 2>/dev/null || true
ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query "associations[?serviceAccount=='aws-pca-issuer' && namespace=='${CERT_MANAGER_NS}'].associationId" --output text 2>/dev/null || true)
[ -n "$ASSOC_ID" ] && aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --region "$AWS_REGION"
helm delete aws-pca-issuer -n "$CERT_MANAGER_NS" 2>/dev/null || true

echo "=== Removing cert-manager ==="
helm delete cert-manager-csi-driver -n "$CERT_MANAGER_NS" 2>/dev/null || true
helm delete cert-manager -n "$CERT_MANAGER_NS" 2>/dev/null || true
kubectl delete ns "$CERT_MANAGER_NS" --ignore-not-found

echo "=== Removing ACM Certificate ==="
aws acm delete-certificate --certificate-arn "$ACM_CERT_ARN" --region "$AWS_REGION" 2>/dev/null || true

echo "=== Removing DNS validation record ==="
VALIDATION_NAME=$(aws acm describe-certificate --certificate-arn "$ACM_CERT_ARN" --region "$AWS_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text 2>/dev/null || true)
VALIDATION_VALUE=$(aws acm describe-certificate --certificate-arn "$ACM_CERT_ARN" --region "$AWS_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text 2>/dev/null || true)
if [ -n "$VALIDATION_NAME" ] && [ "$VALIDATION_NAME" != "None" ]; then
  aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"${VALIDATION_NAME}\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"${VALIDATION_VALUE}\"}]}}]}" 2>/dev/null || true
fi

echo "=== Removing Lambda and dev cert secrets ==="
aws lambda delete-function --function-name e2e-tls-demo-issue-dev-cert --region "$AWS_REGION" 2>/dev/null || true
for svc in greeting-service quote-service; do
  aws secretsmanager delete-secret --secret-id "e2e-tls-demo/dev-certs/$svc" --force-delete-without-recovery --region "$AWS_REGION" 2>/dev/null || true
done

echo "=== Removing IAM resources ==="
for suffix in pca dns lambda; do
  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ROLE_PREFIX}-${suffix}-policy"
  aws iam detach-role-policy --role-name "${ROLE_PREFIX}-${suffix}-role" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam delete-role --role-name "${ROLE_PREFIX}-${suffix}-role" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
done

echo "=== Removing Private CAs (subordinates first, then root) ==="
for CA in "$CLUSTER_CA_ARN" "$DEV_CA_ARN" "$ROOT_CA_ARN"; do
  aws acm-pca update-certificate-authority --certificate-authority-arn "$CA" --status DISABLED --region "$AWS_REGION" 2>/dev/null || true
  aws acm-pca delete-certificate-authority --certificate-authority-arn "$CA" --region "$AWS_REGION" 2>/dev/null || true
done

echo "=== Removing ECR repositories ==="
for svc in quote-service greeting-service; do
  aws ecr delete-repository --repository-name "$svc" --region "$AWS_REGION" --force 2>/dev/null || true
done

echo "=== Teardown complete ==="
