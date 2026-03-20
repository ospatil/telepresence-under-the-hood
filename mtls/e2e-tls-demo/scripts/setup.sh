#!/usr/bin/env bash
#
# E2E TLS Demo Setup
# AWS PCA → cert-manager → Spring Boot TLS → ALB HTTPS → Route53
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

Sets up end-to-end TLS demo: AWS PCA certs on Spring Boot pods behind ALB with Route53 DNS.

Configuration:
  Create a .env file from .env.example and fill in your values:
    cp .env.example .env
    # Edit .env with your values

  Or set environment variables:
    AWS_ACCOUNT_ID   (required)  AWS account ID
    AWS_REGION       (optional)  AWS region (default: ca-central-1)
    DOMAIN           (required)  Route53 domain (e.g., myapp.example.com)
    HOSTED_ZONE_ID   (required)  Route53 hosted zone ID

Example:
  # Using .env file (recommended)
  cp .env.example .env
  # Edit .env
  $0

  # Or using environment variables
  export AWS_ACCOUNT_ID=123456789012
  export DOMAIN=myapp.example.com
  export HOSTED_ZONE_ID=ZXXXXXXXXXXXXX
  $0
EOF
  exit 1
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage
[[ -z "${AWS_ACCOUNT_ID:-}" ]] && echo "Error: AWS_ACCOUNT_ID is not set." && usage
[[ -z "${DOMAIN:-}" ]] && echo "Error: DOMAIN is not set." && usage
[[ -z "${HOSTED_ZONE_ID:-}" ]] && echo "Error: HOSTED_ZONE_ID is not set." && usage

export AWS_REGION="${AWS_REGION:-ca-central-1}"
export DOMAIN
CLUSTER_NAME="auto-mode-private-access"
ROLE_PREFIX="e2e-tls-demo"
CERT_MANAGER_NS="cert-manager"

# ── Phase 1: AWS Private CA Hierarchy ─────────────────────────────────────────

echo "=== Phase 1: AWS Private CA Hierarchy ==="

# Helper: create and activate a subordinate CA signed by the root
create_subordinate_ca() {
  local cn=$1
  local root_arn=$2

  local sub_arn
  sub_arn=$(aws acm-pca create-certificate-authority \
    --certificate-authority-configuration \
      "KeyAlgorithm=EC_prime256v1,SigningAlgorithm=SHA256WITHECDSA,Subject={CommonName=${cn}}" \
    --certificate-authority-type SUBORDINATE \
    --usage-mode GENERAL_PURPOSE \
    --region "$AWS_REGION" \
    --query 'CertificateAuthorityArn' --output text)

  aws acm-pca wait certificate-authority-csr-created \
    --certificate-authority-arn "$sub_arn" --region "$AWS_REGION"

  aws acm-pca get-certificate-authority-csr \
    --certificate-authority-arn "$sub_arn" --region "$AWS_REGION" \
    --output text > /tmp/e2e-sub-ca.csr

  local sub_cert_arn
  sub_cert_arn=$(aws acm-pca issue-certificate \
    --certificate-authority-arn "$root_arn" \
    --csr fileb:///tmp/e2e-sub-ca.csr \
    --signing-algorithm SHA256WITHECDSA \
    --template-arn arn:aws:acm-pca:::template/SubordinateCACertificate_PathLen0/V1 \
    --validity Value=5,Type=YEARS \
    --region "$AWS_REGION" \
    --query 'CertificateArn' --output text)

  aws acm-pca wait certificate-issued \
    --certificate-authority-arn "$root_arn" \
    --certificate-arn "$sub_cert_arn" \
    --region "$AWS_REGION"

  aws acm-pca get-certificate \
    --certificate-authority-arn "$root_arn" \
    --certificate-arn "$sub_cert_arn" \
    --region "$AWS_REGION" \
    --query 'Certificate' --output text > /tmp/e2e-sub-cert.pem

  aws acm-pca get-certificate-authority-certificate \
    --certificate-authority-arn "$root_arn" \
    --region "$AWS_REGION" \
    --query 'Certificate' --output text > /tmp/e2e-root-cert-chain.pem

  aws acm-pca import-certificate-authority-certificate \
    --certificate-authority-arn "$sub_arn" \
    --certificate fileb:///tmp/e2e-sub-cert.pem \
    --certificate-chain fileb:///tmp/e2e-root-cert-chain.pem \
    --region "$AWS_REGION"

  echo "$sub_arn"
}

# 1a. Create and activate root CA
echo "Creating root CA..."
export ROOT_CA_ARN=$(aws acm-pca create-certificate-authority \
  --certificate-authority-configuration \
    "KeyAlgorithm=EC_prime256v1,SigningAlgorithm=SHA256WITHECDSA,Subject={CommonName=e2e-tls-demo-root-ca}" \
  --certificate-authority-type ROOT \
  --usage-mode GENERAL_PURPOSE \
  --region "$AWS_REGION" \
  --query 'CertificateAuthorityArn' --output text)
echo "Root CA ARN: $ROOT_CA_ARN"

echo "Waiting for root CA..."
aws acm-pca wait certificate-authority-csr-created \
  --certificate-authority-arn "$ROOT_CA_ARN" --region "$AWS_REGION"

aws acm-pca get-certificate-authority-csr \
  --certificate-authority-arn "$ROOT_CA_ARN" --region "$AWS_REGION" \
  --output text > /tmp/e2e-ca.csr

ROOT_CERT_ARN=$(aws acm-pca issue-certificate \
  --certificate-authority-arn "$ROOT_CA_ARN" \
  --csr fileb:///tmp/e2e-ca.csr \
  --signing-algorithm SHA256WITHECDSA \
  --template-arn arn:aws:acm-pca:::template/RootCACertificate/V1 \
  --validity Value=10,Type=YEARS \
  --region "$AWS_REGION" \
  --query 'CertificateArn' --output text)

aws acm-pca wait certificate-issued \
  --certificate-authority-arn "$ROOT_CA_ARN" \
  --certificate-arn "$ROOT_CERT_ARN" \
  --region "$AWS_REGION"

aws acm-pca get-certificate \
  --certificate-authority-arn "$ROOT_CA_ARN" \
  --certificate-arn "$ROOT_CERT_ARN" \
  --region "$AWS_REGION" \
  --query 'Certificate' --output text > /tmp/e2e-root-cert.pem

aws acm-pca import-certificate-authority-certificate \
  --certificate-authority-arn "$ROOT_CA_ARN" \
  --certificate fileb:///tmp/e2e-root-cert.pem \
  --region "$AWS_REGION"

echo "Root CA activated."

# 1b. Create cluster subordinate CA
echo "Creating cluster subordinate CA..."
export CLUSTER_CA_ARN=$(create_subordinate_ca "e2e-tls-demo-cluster-ca" "$ROOT_CA_ARN")
echo "Cluster CA ARN: $CLUSTER_CA_ARN"

# 1c. Create developer subordinate CA
echo "Creating developer subordinate CA..."
export DEV_CA_ARN=$(create_subordinate_ca "e2e-tls-demo-dev-ca" "$ROOT_CA_ARN")
echo "Dev CA ARN: $DEV_CA_ARN"

# Save ARNs to .env
if [[ -f "$PROJECT_DIR/.env" ]]; then
  for var in ROOT_CA_ARN CLUSTER_CA_ARN DEV_CA_ARN; do
    if grep -q "^${var}=" "$PROJECT_DIR/.env"; then
      sed -i '' "s|^${var}=.*|${var}=${!var}|" "$PROJECT_DIR/.env"
    else
      echo "${var}=${!var}" >> "$PROJECT_DIR/.env"
    fi
  done
fi

# IAM for PCA issuer (cert-manager needs access to cluster CA)
PCA_POLICY_ARN=$(aws iam create-policy \
  --policy-name "${ROLE_PREFIX}-pca-policy" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"acm-pca:IssueCertificate\",\"acm-pca:GetCertificate\",\"acm-pca:DescribeCertificateAuthority\",\"acm-pca:GetCertificateAuthorityCertificate\"],
      \"Resource\": \"${CLUSTER_CA_ARN}\"
    }]
  }" --query 'Policy.Arn' --output text)

aws iam create-role --role-name "${ROLE_PREFIX}-pca-role" \
  --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]
  }' > /dev/null
aws iam attach-role-policy --role-name "${ROLE_PREFIX}-pca-role" --policy-arn "$PCA_POLICY_ARN"

# ── Phase 1b: Lambda for dev cert issuance ────────────────────────────────────

echo "=== Phase 1b: Dev cert Lambda ==="

LAMBDA_NAME="e2e-tls-demo-issue-dev-cert"

# IAM role for Lambda
LAMBDA_POLICY_ARN=$(aws iam create-policy \
  --policy-name "${ROLE_PREFIX}-lambda-policy" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"acm-pca:IssueCertificate\",\"acm-pca:GetCertificate\",\"acm-pca:GetCertificateAuthorityCertificate\"],
        \"Resource\": [\"${DEV_CA_ARN}\",\"${ROOT_CA_ARN}\"]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"secretsmanager:GetSecretValue\",\"secretsmanager:PutSecretValue\",\"secretsmanager:CreateSecret\"],
        \"Resource\": \"arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:e2e-tls-demo/dev-certs/*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],
        \"Resource\": \"*\"
      }
    ]
  }" --query 'Policy.Arn' --output text)

aws iam create-role --role-name "${ROLE_PREFIX}-lambda-role" \
  --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' > /dev/null
aws iam attach-role-policy --role-name "${ROLE_PREFIX}-lambda-role" --policy-arn "$LAMBDA_POLICY_ARN"

echo "Waiting for IAM role propagation..."
sleep 10

# Package and deploy Lambda
(cd "$PROJECT_DIR/lambda" && pip install cryptography cffi --platform manylinux2014_x86_64 --implementation cp --python-version 3.12 --only-binary=:all: -t . -q && zip -q -r /tmp/e2e-tls-lambda.zip .)

aws lambda create-function \
  --function-name "$LAMBDA_NAME" \
  --runtime python3.12 \
  --handler issue_dev_cert.handler \
  --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_PREFIX}-lambda-role" \
  --zip-file fileb:///tmp/e2e-tls-lambda.zip \
  --timeout 30 \
  --environment "Variables={DEV_CA_ARN=${DEV_CA_ARN},ROOT_CA_ARN=${ROOT_CA_ARN},VALIDITY_DAYS=30}" \
  --region "$AWS_REGION" > /dev/null

echo "Lambda deployed: $LAMBDA_NAME"

# ── Phase 2: cert-manager + AWS PCA Issuer ───────────────────────────────────

echo "=== Phase 2: cert-manager + AWS PCA Issuer ==="

helm repo add jetstack https://charts.jetstack.io
helm repo add awspca https://cert-manager.github.io/aws-privateca-issuer
helm repo update

if ! helm status cert-manager -n "$CERT_MANAGER_NS" &>/dev/null; then
  helm install cert-manager jetstack/cert-manager \
    -n "$CERT_MANAGER_NS" --create-namespace --set crds.enabled=true --wait
fi

# Install cert-manager CSI driver
if ! helm status cert-manager-csi-driver -n "$CERT_MANAGER_NS" &>/dev/null; then
  helm install cert-manager-csi-driver jetstack/cert-manager-csi-driver \
    -n "$CERT_MANAGER_NS" --wait
fi

if ! helm status aws-pca-issuer -n "$CERT_MANAGER_NS" &>/dev/null; then
  helm install aws-pca-issuer awspca/aws-privateca-issuer \
    -n "$CERT_MANAGER_NS" --set serviceAccount.name=aws-pca-issuer --wait
fi

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --namespace "$CERT_MANAGER_NS" \
  --service-account aws-pca-issuer \
  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_PREFIX}-pca-role" \
  --region "$AWS_REGION"

kubectl rollout restart deployment -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name=aws-privateca-issuer
kubectl rollout status deployment -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name=aws-privateca-issuer --timeout=60s

kubectl apply -f - <<EOF
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAClusterIssuer
metadata:
  name: aws-pca-issuer
spec:
  arn: ${CLUSTER_CA_ARN}
  region: ${AWS_REGION}
EOF

kubectl wait --for=condition=Ready awspcaclusterissuer/aws-pca-issuer --timeout=60s

# ── Phase 3: external-dns ────────────────────────────────────────────────────

echo "=== Phase 3: external-dns ==="

# IAM for external-dns
DNS_POLICY_ARN=$(aws iam create-policy \
  --policy-name "${ROLE_PREFIX}-dns-policy" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\":\"Allow\",\"Action\":[\"route53:ChangeResourceRecordSets\"],\"Resource\":\"arn:aws:route53:::hostedzone/${HOSTED_ZONE_ID}\"},
      {\"Effect\":\"Allow\",\"Action\":[\"route53:ListHostedZones\",\"route53:ListResourceRecordSets\",\"route53:ListTagsForResource\"],\"Resource\":\"*\"}
    ]
  }" --query 'Policy.Arn' --output text)

aws iam create-role --role-name "${ROLE_PREFIX}-dns-role" \
  --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]
  }' > /dev/null
aws iam attach-role-policy --role-name "${ROLE_PREFIX}-dns-role" --policy-arn "$DNS_POLICY_ARN"

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns 2>/dev/null || true
if ! helm status external-dns -n kube-system &>/dev/null; then
  helm install external-dns external-dns/external-dns -n kube-system \
    --set provider.name=aws \
    --set "domainFilters[0]=${DOMAIN}" \
    --set policy=sync \
    --set "sources[0]=ingress" \
    --set serviceAccount.name=external-dns \
    --wait
fi

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --namespace kube-system \
  --service-account external-dns \
  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_PREFIX}-dns-role" \
  --region "$AWS_REGION"

kubectl rollout restart deployment external-dns -n kube-system
kubectl rollout status deployment external-dns -n kube-system --timeout=60s

# ── Phase 4: ACM Certificate for ALB ─────────────────────────────────────────

echo "=== Phase 4: ACM Certificate ==="

export ACM_CERT_ARN=$(aws acm request-certificate \
  --domain-name "greeting.${DOMAIN}" \
  --validation-method DNS \
  --region "$AWS_REGION" \
  --query 'CertificateArn' --output text)
echo "ACM Cert ARN: $ACM_CERT_ARN"

echo "Waiting for DNS validation record..."
sleep 10

VALIDATION_JSON=$(aws acm describe-certificate \
  --certificate-arn "$ACM_CERT_ARN" --region "$AWS_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord')

VALIDATION_NAME=$(echo "$VALIDATION_JSON" | jq -r '.Name')
VALIDATION_VALUE=$(echo "$VALIDATION_JSON" | jq -r '.Value')

echo "Creating DNS validation record..."
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Changes\":[{
      \"Action\":\"UPSERT\",
      \"ResourceRecordSet\":{
        \"Name\":\"${VALIDATION_NAME}\",
        \"Type\":\"CNAME\",
        \"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"${VALIDATION_VALUE}\"}]
      }
    }]
  }"

echo "Waiting for ACM certificate validation (this may take a few minutes)..."
aws acm wait certificate-validated --certificate-arn "$ACM_CERT_ARN" --region "$AWS_REGION"
echo "ACM certificate validated."

# Save ACM_CERT_ARN to .env
if [[ -f "$PROJECT_DIR/.env" ]]; then
  if grep -q '^ACM_CERT_ARN=' "$PROJECT_DIR/.env"; then
    sed -i '' "s|^ACM_CERT_ARN=.*|ACM_CERT_ARN=${ACM_CERT_ARN}|" "$PROJECT_DIR/.env"
  else
    echo "ACM_CERT_ARN=${ACM_CERT_ARN}" >> "$PROJECT_DIR/.env"
  fi
fi

# ── Phase 5: Build & Push Docker Images ──────────────────────────────────────

echo "=== Phase 5: Build & Push ==="

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

for svc in quote-service greeting-service; do
  aws ecr describe-repositories --repository-names "$svc" --region "$AWS_REGION" 2>/dev/null || \
    aws ecr create-repository --repository-name "$svc" --region "$AWS_REGION" > /dev/null

  echo "Building $svc..."
  (cd "$PROJECT_DIR/$svc" && ./mvnw -q clean package -DskipTests)
  docker build --platform linux/amd64 -t "$ECR_REGISTRY/$svc:latest" "$PROJECT_DIR/$svc"
  docker push "$ECR_REGISTRY/$svc:latest"
done

# ── Phase 6: Deploy ──────────────────────────────────────────────────────────

echo "=== Phase 6: Deploy ==="

kubectl create ns greeting-service-ns --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns quote-service-ns --dry-run=client -o yaml | kubectl apply -f -

# Deployments (substitute env vars) - CSI driver provisions certs automatically
for svc in quote-service greeting-service; do
  envsubst < "$PROJECT_DIR/$svc/k8s/deployment.yaml" | kubectl apply -f -
done

kubectl wait --for=condition=Ready pod -l app=quote-service -n quote-service-ns --timeout=120s
kubectl wait --for=condition=Ready pod -l app=greeting-service -n greeting-service-ns --timeout=120s

# Ingress
envsubst < "$PROJECT_DIR/greeting-service/k8s/ingress.yaml" | kubectl apply -f -

# ── Phase 7: Validate ────────────────────────────────────────────────────────

echo "=== Phase 7: Validation ==="

echo "Waiting for ALB provisioning..."
for i in $(seq 1 30); do
  ALB_HOST=$(kubectl get ingress greeting-service -n greeting-service-ns -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$ALB_HOST" ]; then
    echo "ALB: $ALB_HOST"
    break
  fi
  sleep 10
done

echo "Waiting for DNS propagation..."
for i in $(seq 1 30); do
  if dig +short "greeting.${DOMAIN}" | grep -q .; then
    echo "DNS resolved."
    break
  fi
  sleep 10
done

echo "Testing endpoint..."
sleep 15
curl -s "https://greeting.${DOMAIN}/greeting" | jq . || echo "Endpoint not ready yet — ALB may still be provisioning."

echo ""
echo "=== Setup Complete ==="
echo "Root CA ARN:    $ROOT_CA_ARN"
echo "Cluster CA ARN: $CLUSTER_CA_ARN"
echo "Dev CA ARN:     $DEV_CA_ARN"
echo "ACM Cert ARN:   $ACM_CERT_ARN"
echo "Endpoint:       https://greeting.${DOMAIN}/greeting"
echo ""
echo "Note: Certificates are provisioned via CSI driver directly into pods."
echo "No Kubernetes Secrets are created - certs exist only in pod filesystem."
