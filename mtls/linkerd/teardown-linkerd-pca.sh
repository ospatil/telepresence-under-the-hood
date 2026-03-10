#!/usr/bin/env bash
#
# Teardown Linkerd + AWS Private CA
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: AWS_ACCOUNT_ID=<account-id> $0 [--ca-arn <ca-arn>]

Tears down Linkerd + AWS Private CA setup.

Environment variables:
  AWS_ACCOUNT_ID  (required)  Your AWS account ID

Options:
  --ca-arn <arn>  Also delete the AWS Private CA (skip if shared with other demos)

Example:
  export AWS_ACCOUNT_ID=123456789012
  $0
  $0 --ca-arn arn:aws:acm-pca:ca-central-1:123456789012:certificate-authority/xxx
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage
[[ -z "${AWS_ACCOUNT_ID:-}" ]] && echo "Error: AWS_ACCOUNT_ID is not set." && usage

CLUSTER_NAME="auto-mode-private-access"
REGION="ca-central-1"
ROLE_NAME="aws-pca-issuer-role-linkerd"
POLICY_NAME="aws-pca-issuer-policy-linkerd"
CERT_MANAGER_NS="cert-manager"
LINKERD_NS="linkerd"
CA_ARN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --ca-arn) CA_ARN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

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
kubectl delete -f linkerd-pca-certs.yaml 2>/dev/null || true
kubectl delete ns "$LINKERD_NS" --ignore-not-found
kubectl delete ns "$LINKERD_NS" --ignore-not-found

echo "=== Removing AWS PCA Issuer ==="
kubectl delete awspcaclusterissuer aws-pca-issuer 2>/dev/null || true
helm delete aws-pca-issuer -n "$CERT_MANAGER_NS" 2>/dev/null || true

echo "=== Removing cert-manager ==="
helm delete cert-manager -n "$CERT_MANAGER_NS" 2>/dev/null || true
kubectl delete ns "$CERT_MANAGER_NS" --ignore-not-found

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

if [ -n "$CA_ARN" ]; then
  echo "=== Deleting Private CA ==="
  aws acm-pca update-certificate-authority \
    --certificate-authority-arn "$CA_ARN" --status DISABLED --region "$REGION" 2>/dev/null || true
  aws acm-pca delete-certificate-authority \
    --certificate-authority-arn "$CA_ARN" --region "$REGION" 2>/dev/null || true
else
  echo "Skipping CA deletion (use --ca-arn to delete)."
fi

echo "=== Teardown complete ==="
