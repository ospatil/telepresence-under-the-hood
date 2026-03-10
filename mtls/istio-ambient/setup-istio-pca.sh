#!/usr/bin/env bash
#
# Istio Ambient + AWS Private CA Setup
# EKS Auto Mode with Pod Identity
#
# Prerequisites:
#   - EKS cluster "auto-mode-private-access" running in ca-central-1
#   - kubectl configured and connected (via SSM port-forward)
#   - helm 3.6+, aws cli v2, jq
#
# Usage:
#   export AWS_ACCOUNT_ID=123456789012
#   ./setup-istio-pca.sh

set -euo pipefail

usage() {
  cat <<EOF
Usage: AWS_ACCOUNT_ID=<account-id> $0 [--ca-arn <existing-ca-arn>]

Sets up Istio Ambient with AWS Private CA on EKS Auto Mode (Pod Identity).

Prerequisites:
  - EKS cluster "auto-mode-private-access" running in ca-central-1
  - kubectl configured and connected (via SSM port-forward)
  - helm 3.6+, aws cli v2, istioctl, jq

Environment variables:
  AWS_ACCOUNT_ID  (required)  Your AWS account ID

Options:
  --ca-arn <arn>  Reuse an existing AWS Private CA (skips CA creation)

Example:
  export AWS_ACCOUNT_ID=123456789012
  $0

  # Reuse CA from Linkerd PCA demo:
  $0 --ca-arn arn:aws:acm-pca:ca-central-1:123456789012:certificate-authority/xxx
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage
[[ -z "${AWS_ACCOUNT_ID:-}" ]] && echo "Error: AWS_ACCOUNT_ID is not set." && usage

CLUSTER_NAME="auto-mode-private-access"
export REGION="ca-central-1"
CA_COMMON_NAME="mesh-ca.cluster.local"
ROLE_NAME="aws-pca-issuer-role"
POLICY_NAME="aws-pca-issuer-policy"
SA_NAME="aws-pca-issuer"
CERT_MANAGER_NS="cert-manager"
ISTIO_NS="istio-system"
export CA_ARN=""

# Parse --ca-arn
while [[ $# -gt 0 ]]; do
  case $1 in
    --ca-arn) CA_ARN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "=== Phase 0: AWS Private CA ==="

if [ -n "$CA_ARN" ]; then
  echo "Reusing existing CA: $CA_ARN"
else
  echo "Creating Private CA (short-lived mode)..."
  CA_ARN=$(aws acm-pca create-certificate-authority \
    --certificate-authority-configuration \
      "KeyAlgorithm=EC_prime256v1,SigningAlgorithm=SHA256WITHECDSA,Subject={CommonName=${CA_COMMON_NAME}}" \
    --certificate-authority-type ROOT \
    --usage-mode SHORT_LIVED_CERTIFICATE \
    --region "$REGION" \
    --query 'CertificateAuthorityArn' --output text)
  echo "CA ARN: $CA_ARN"

  echo "Waiting for CA to be PENDING_CERTIFICATE..."
  aws acm-pca wait certificate-authority-csr-created \
    --certificate-authority-arn "$CA_ARN" --region "$REGION"

  echo "Fetching CSR..."
  aws acm-pca get-certificate-authority-csr \
    --certificate-authority-arn "$CA_ARN" --region "$REGION" \
    --output text > /tmp/ca.csr

  echo "Issuing self-signed root certificate..."
  ROOT_CERT_ARN=$(aws acm-pca issue-certificate \
    --certificate-authority-arn "$CA_ARN" \
    --csr fileb:///tmp/ca.csr \
    --signing-algorithm SHA256WITHECDSA \
    --template-arn arn:aws:acm-pca:::template/RootCACertificate/V1 \
    --validity Value=10,Type=YEARS \
    --region "$REGION" \
    --query 'CertificateArn' --output text)

  echo "Waiting for certificate to be issued..."
  aws acm-pca wait certificate-issued \
    --certificate-authority-arn "$CA_ARN" \
    --certificate-arn "$ROOT_CERT_ARN" \
    --region "$REGION"

  echo "Fetching and importing root certificate..."
  aws acm-pca get-certificate \
    --certificate-authority-arn "$CA_ARN" \
    --certificate-arn "$ROOT_CERT_ARN" \
    --region "$REGION" \
    --query 'Certificate' --output text > /tmp/root-cert.pem

  aws acm-pca import-certificate-authority-certificate \
    --certificate-authority-arn "$CA_ARN" \
    --certificate fileb:///tmp/root-cert.pem \
    --region "$REGION"

  echo "CA activated."
fi

echo "Creating IAM policy..."
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "IAM role $ROLE_NAME already exists, skipping."
  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
else
  POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Action\": [
          \"acm-pca:IssueCertificate\",
          \"acm-pca:GetCertificate\",
          \"acm-pca:DescribeCertificateAuthority\"
        ],
        \"Resource\": \"${CA_ARN}\"
      }]
    }" \
    --query 'Policy.Arn' --output text)

  echo "Creating IAM role for Pod Identity..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": { "Service": "pods.eks.amazonaws.com" },
        "Action": ["sts:AssumeRole", "sts:TagSession"]
      }]
    }' > /dev/null

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN"
fi

echo "=== Phase 1: cert-manager + AWS PCA Issuer ==="

helm repo add jetstack https://charts.jetstack.io
helm repo add awspca https://cert-manager.github.io/aws-privateca-issuer
helm repo update

if helm status cert-manager -n "$CERT_MANAGER_NS" &>/dev/null; then
  echo "cert-manager already installed, skipping."
else
  echo "Installing cert-manager..."
  helm install cert-manager jetstack/cert-manager \
    -n "$CERT_MANAGER_NS" --create-namespace \
    --set crds.enabled=true --wait
fi

if helm status aws-pca-issuer -n "$CERT_MANAGER_NS" &>/dev/null; then
  echo "aws-privateca-issuer already installed, skipping."
else
  echo "Installing aws-privateca-issuer..."
  helm install aws-pca-issuer awspca/aws-privateca-issuer \
    -n "$CERT_MANAGER_NS" \
    --set serviceAccount.name="$SA_NAME" \
    --wait
fi

EXISTING_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --query "associations[?serviceAccount=='${SA_NAME}' && namespace=='${CERT_MANAGER_NS}'].associationId" \
  --output text 2>/dev/null || true)
if [ -z "$EXISTING_ASSOC" ]; then
  echo "Creating Pod Identity association..."
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace "$CERT_MANAGER_NS" \
    --service-account "$SA_NAME" \
    --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}" \
    --region "$REGION"

  echo "Restarting aws-pca-issuer to pick up Pod Identity credentials..."
  kubectl rollout restart deployment -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name=aws-privateca-issuer
  kubectl rollout status deployment -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name=aws-privateca-issuer --timeout=60s
else
  echo "Pod Identity association already exists, skipping."
fi

echo "Creating AWSPCAClusterIssuer..."
envsubst < ../aws-pca-issuer.yaml.tpl | kubectl apply -f -

echo "Waiting for issuer to be ready..."
kubectl wait --for=condition=Ready awspcaclusterissuer/aws-pca-issuer --timeout=60s

echo "=== Phase 2: istio-csr ==="

echo "Creating istio-system namespace..."
kubectl create ns "$ISTIO_NS" --dry-run=client -o yaml | kubectl apply -f -

echo "Installing istio-csr..."
helm install istio-csr jetstack/cert-manager-istio-csr \
  -n "$CERT_MANAGER_NS" \
  --set app.certmanager.issuer.name=aws-pca-issuer \
  --set app.certmanager.issuer.kind=AWSPCAClusterIssuer \
  --set app.certmanager.issuer.group=awspca.cert-manager.io \
  --set app.server.caTrustedNodeAccounts=istio-system/ztunnel \
  --wait

echo "=== Phase 3: Istio Ambient ==="

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

echo "Installing Istio base CRDs..."
helm install istio-base istio/base -n "$ISTIO_NS" --wait

echo "Installing istiod (external CA mode)..."
helm install istiod istio/istiod -n "$ISTIO_NS" \
  --set profile=ambient \
  --set pilot.env.ENABLE_CA_SERVER=false \
  --wait

echo "Installing istio-cni..."
helm install istio-cni istio/cni -n "$ISTIO_NS" --set profile=ambient --wait

echo "Installing ztunnel..."
helm install ztunnel istio/ztunnel -n "$ISTIO_NS" \
  --set caAddress=cert-manager-istio-csr.cert-manager.svc:443 \
  --wait

echo "=== Phase 4: Deploy Services ==="

echo "Creating namespaces with ambient mesh enrollment..."
kubectl create ns service-c-ns --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns service-d-ns --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns service-c-ns istio.io/dataplane-mode=ambient --overwrite
kubectl label ns service-d-ns istio.io/dataplane-mode=ambient --overwrite

echo "Deploying services..."
kubectl apply -f ../../services/d-manifest.yaml
kubectl apply -f ../../services/c-manifest.yaml

echo "Waiting for pods..."
kubectl wait --for=condition=Ready pod -l app=service-d -n service-d-ns --timeout=120s
kubectl wait --for=condition=Ready pod -l app=service-c -n service-c-ns --timeout=120s

echo "=== Phase 5: Validation ==="

echo "Checking ztunnel enrollment..."
istioctl ztunnel-config workloads | grep -E 'service-c|service-d' || echo "WARNING: istioctl not found or services not enrolled yet"

echo "Testing service chain..."
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n default \
  -- curl -s --max-time 10 service-c.service-c-ns:8080

echo ""
echo "=== Setup Complete ==="
echo "CA ARN: $CA_ARN"
echo ""
echo "Next steps:"
echo "  - Validate mTLS with tcpdump (see istio-ambient-demo.md Phase 3.2)"
echo "  - Test Telepresence intercepts (see istio-ambient-demo.md Phase 4)"
echo "  - Verify certs are from AWS PCA:"
echo "    istioctl proxy-config secret \$(kubectl get pods -n istio-system -l app=ztunnel -o jsonpath='{.items[0].metadata.name}') -n istio-system -o json | jq '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain'"
