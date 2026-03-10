#!/usr/bin/env bash
#
# Linkerd mTLS + AWS Private CA Setup
# EKS Auto Mode with Pod Identity
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: AWS_ACCOUNT_ID=<account-id> $0 [--ca-arn <existing-ca-arn>]

Sets up Linkerd mTLS with AWS Private CA on EKS Auto Mode (Pod Identity).
Replaces the self-signed bootstrap with AWS PCA as the trust anchor root.

Certificate hierarchy:
  AWS Private CA (general purpose mode — acts as trust anchor)
        └── linkerd-identity-issuer (Intermediate CA, 1y, cert-manager auto-rotates)
              └── Workload certs (24h, Linkerd auto-manages)

Prerequisites:
  - EKS cluster "auto-mode-private-access" running in ca-central-1
  - kubectl configured and connected (via SSM port-forward)
  - helm 3.6+, aws cli v2, linkerd CLI
  - service-a and service-b already deployed (services/a-manifest.yaml, services/b-manifest.yaml)

Environment variables:
  AWS_ACCOUNT_ID  (required)  Your AWS account ID

Options:
  --ca-arn <arn>  Reuse an existing AWS Private CA (skips CA creation)

Example:
  export AWS_ACCOUNT_ID=123456789012
  $0

  # Reuse CA from Istio PCA demo:
  $0 --ca-arn arn:aws:acm-pca:ca-central-1:123456789012:certificate-authority/xxx
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage
[[ -z "${AWS_ACCOUNT_ID:-}" ]] && echo "Error: AWS_ACCOUNT_ID is not set." && usage

CLUSTER_NAME="auto-mode-private-access"
export REGION="ca-central-1"
CA_COMMON_NAME="mesh-ca.cluster.local"
ROLE_NAME="aws-pca-issuer-role-linkerd"
POLICY_NAME="aws-pca-issuer-policy-linkerd"
SA_NAME="aws-pca-issuer"
CERT_MANAGER_NS="cert-manager"
LINKERD_NS="linkerd"
export CA_ARN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --ca-arn) CA_ARN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── Phase 0: AWS Private CA ──────────────────────────────────────────────────

if [ -n "$CA_ARN" ]; then
  echo "=== Phase 0: Reusing existing CA: $CA_ARN ==="
else
  echo "=== Phase 0: Creating AWS Private CA ==="

  CA_ARN=$(aws acm-pca create-certificate-authority \
    --certificate-authority-configuration \
      "KeyAlgorithm=EC_prime256v1,SigningAlgorithm=SHA256WITHECDSA,Subject={CommonName=${CA_COMMON_NAME}}" \
    --certificate-authority-type ROOT \
    --usage-mode GENERAL_PURPOSE \
    --region "$REGION" \
    --query 'CertificateAuthorityArn' --output text)
  echo "CA ARN: $CA_ARN"

  echo "Waiting for CA..."
  aws acm-pca wait certificate-authority-csr-created \
    --certificate-authority-arn "$CA_ARN" --region "$REGION"

  aws acm-pca get-certificate-authority-csr \
    --certificate-authority-arn "$CA_ARN" --region "$REGION" \
    --output text > /tmp/ca.csr

  ROOT_CERT_ARN=$(aws acm-pca issue-certificate \
    --certificate-authority-arn "$CA_ARN" \
    --csr fileb:///tmp/ca.csr \
    --signing-algorithm SHA256WITHECDSA \
    --template-arn arn:aws:acm-pca:::template/RootCACertificate/V1 \
    --validity Value=10,Type=YEARS \
    --region "$REGION" \
    --query 'CertificateArn' --output text)

  aws acm-pca wait certificate-issued \
    --certificate-authority-arn "$CA_ARN" \
    --certificate-arn "$ROOT_CERT_ARN" \
    --region "$REGION"

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

# IAM
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "IAM role $ROLE_NAME already exists, skipping."
  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
else
  echo "Creating IAM policy and role..."
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

# ── Phase 1: cert-manager + AWS PCA Issuer ───────────────────────────────────

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

# Pod Identity association
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

  kubectl rollout restart deployment -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name=aws-privateca-issuer
  kubectl rollout status deployment -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name=aws-privateca-issuer --timeout=60s
else
  echo "Pod Identity association already exists, skipping."
fi

echo "Creating AWSPCAClusterIssuer..."
envsubst < ../aws-pca-issuer.yaml.tpl | kubectl apply -f -

kubectl wait --for=condition=Ready awspcaclusterissuer/aws-pca-issuer --timeout=60s

# ── Phase 2: Linkerd Certificate Infrastructure ──────────────────────────────

echo "=== Phase 2: Linkerd Certificate Infrastructure (backed by AWS PCA) ==="

kubectl create ns "$LINKERD_NS" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating trust anchor and identity issuer certificates..."
kubectl apply -f linkerd-pca-certs.yaml

echo "Waiting for certificates to be ready..."
kubectl wait --for=condition=Ready certificate/linkerd-identity-issuer -n "$LINKERD_NS" --timeout=120s

echo "Extracting trust anchor (PCA root cert) for Linkerd install..."
aws acm-pca get-certificate-authority-certificate \
  --certificate-authority-arn "$CA_ARN" --region "$REGION" \
  --query 'Certificate' --output text > /tmp/linkerd-ca.crt

# ── Phase 3: Install Linkerd ─────────────────────────────────────────────────

echo "=== Phase 3: Install Linkerd ==="

echo "Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

helm repo add linkerd-edge https://helm.linkerd.io/edge
helm repo update

echo "Installing Linkerd CRDs..."
helm install linkerd-crds linkerd-edge/linkerd-crds -n "$LINKERD_NS" --wait

echo "Installing Linkerd control plane..."
helm install linkerd-control-plane linkerd-edge/linkerd-control-plane \
  -n "$LINKERD_NS" \
  --set-file identityTrustAnchorsPEM=/tmp/linkerd-ca.crt \
  --set identity.issuer.scheme=kubernetes.io/tls \
  --wait

echo "Validating Linkerd installation..."
linkerd check || echo "WARNING: linkerd check reported issues"

# ── Phase 4: Mesh the Services ───────────────────────────────────────────────

echo "=== Phase 4: Mesh service-a and service-b ==="

kubectl annotate ns service-a-ns linkerd.io/inject=enabled --overwrite
kubectl annotate ns service-b-ns linkerd.io/inject=enabled --overwrite

kubectl rollout restart deployment/service-a-deployment -n service-a-ns
kubectl rollout restart deployment/service-b-deployment -n service-b-ns

kubectl rollout status deployment/service-a-deployment -n service-a-ns --timeout=120s
kubectl rollout status deployment/service-b-deployment -n service-b-ns --timeout=120s

echo "Verifying sidecars..."
kubectl get pods -n service-a-ns -o jsonpath='{.items[*].spec.containers[*].name}'
echo ""
kubectl get pods -n service-b-ns -o jsonpath='{.items[*].spec.containers[*].name}'
echo ""

# ── Phase 5: Validation ──────────────────────────────────────────────────────

echo "=== Phase 5: Validation ==="

echo "Testing service chain..."
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n default -- \
  curl -s --max-time 10 service-a.service-a-ns:8080

echo ""
echo "Checking mTLS edges..."
linkerd viz install | kubectl apply -f - 2>/dev/null
sleep 10
linkerd viz edges deploy -n service-a-ns 2>/dev/null || echo "(viz may need a moment to collect data)"

echo ""
echo "=== Setup Complete ==="
echo "CA ARN: $CA_ARN"
echo ""
echo "Certificate chain:"
echo "  AWS Private CA (${CA_ARN}) — trust anchor"
echo "    └── linkerd-identity-issuer (Intermediate CA, cert-manager)"
echo "          └── Workload certs (24h, Linkerd)"
echo ""
echo "Next steps:"
echo "  - Validate mTLS with tcpdump (see mtls-demo.md Phase 3.6)"
echo "  - Test Telepresence intercepts (see mtls-demo.md Phase 4)"
echo "  - Check cert issuer:"
echo "    kubectl get secret linkerd-trust-anchor -n linkerd -o jsonpath='{.data.ca\\.crt}' | base64 -d | openssl x509 -text -noout | grep Issuer"
