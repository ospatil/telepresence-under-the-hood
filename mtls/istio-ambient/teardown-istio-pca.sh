#!/usr/bin/env bash
#
# Teardown Istio Ambient + AWS Private CA
#
# Usage:
#   export AWS_ACCOUNT_ID=123456789012
#   export CA_ARN=arn:aws:acm-pca:ca-central-1:123456789012:certificate-authority/xxx
#   ./teardown-istio-pca.sh

set -euo pipefail

usage() {
  cat <<EOF
Usage: AWS_ACCOUNT_ID=<account-id> CA_ARN=<ca-arn> $0

Tears down Istio Ambient + AWS Private CA setup.

Environment variables:
  AWS_ACCOUNT_ID  (required)  Your AWS account ID
  CA_ARN          (required)  The Private CA ARN (from setup script output)

Example:
  export AWS_ACCOUNT_ID=123456789012
  export CA_ARN=arn:aws:acm-pca:ca-central-1:123456789012:certificate-authority/xxx
  $0
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage
[[ -z "${AWS_ACCOUNT_ID:-}" ]] && echo "Error: AWS_ACCOUNT_ID is not set." && usage
[[ -z "${CA_ARN:-}" ]] && echo "Error: CA_ARN is not set." && usage

CLUSTER_NAME="auto-mode-private-access"
REGION="ca-central-1"
ROLE_NAME="aws-pca-issuer-role"
POLICY_NAME="aws-pca-issuer-policy"
CERT_MANAGER_NS="cert-manager"
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

echo "=== Removing istio-csr ==="
helm delete istio-csr -n "$CERT_MANAGER_NS" 2>/dev/null || true

echo "=== Removing AWS PCA Issuer ==="
kubectl delete awspcaclusterissuer aws-pca-issuer 2>/dev/null || true
helm delete aws-pca-issuer -n "$CERT_MANAGER_NS" 2>/dev/null || true

echo "=== Removing cert-manager ==="
helm delete cert-manager -n "$CERT_MANAGER_NS" 2>/dev/null || true
kubectl delete ns "$CERT_MANAGER_NS" "$ISTIO_NS" --ignore-not-found

echo "=== Removing Pod Identity association ==="
ASSOC_ID=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --query "associations[?serviceAccount=='aws-pca-issuer' && namespace=='cert-manager'].associationId" \
  --output text 2>/dev/null || true)
if [ -n "$ASSOC_ID" ]; then
  aws eks delete-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --region "$REGION"
fi

echo "=== Removing IAM resources ==="
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true

echo "=== Disabling and deleting Private CA ==="
aws acm-pca update-certificate-authority \
  --certificate-authority-arn "$CA_ARN" --status DISABLED --region "$REGION" 2>/dev/null || true
aws acm-pca delete-certificate-authority \
  --certificate-authority-arn "$CA_ARN" --region "$REGION" 2>/dev/null || true

echo "=== Teardown complete ==="
