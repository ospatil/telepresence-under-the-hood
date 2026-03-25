# E2E TLS Demo - Guided Runbook

This is a step-by-step guided demo for showing mTLS in action. Load this doc in a Kiro CLI session and ask to execute steps one at a time.

Steps marked with **[MANUAL]** require you to run the command in a separate terminal. All other steps will be executed by Kiro.

## Prerequisites

- Infrastructure is up (`setup.sh` has been run)
- Telepresence client installed
- `.env` file populated with ARNs

---

## Step 1: Show AWS infrastructure

Let's start by looking at the AWS resources backing this demo - the PCA hierarchy, ACM certificate, and the ALB fronting our services.

```bash
# PCA hierarchy - root (general-purpose) + two subordinates (short-lived)
aws acm-pca list-certificate-authorities --region ca-central-1 \
  --query 'CertificateAuthorities[?Status==`ACTIVE`].[CertificateAuthorityConfiguration.Subject.CommonName,Type,UsageMode,Status]' \
  --output table

# ACM certificate for the public domain
aws acm list-certificates --region ca-central-1 \
  --query 'CertificateSummaryList[?DomainName==`greeting.fcc.ospatil.people.aws.dev`].[DomainName,Status]' \
  --output table

# ALB serving the ingress
aws elbv2 describe-load-balancers --region ca-central-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName,`greeting`)].[LoadBalancerName,DNSName,State.Code]' \
  --output table
```

---

## Step 2: Verify pods are running - no sidecars

Now let's look at the application pods. Notice they show 1/1 READY - there are no mesh sidecars. TLS is handled entirely by the application, not by a proxy.

```bash
kubectl get pods -n greeting-service-ns -o wide
kubectl get pods -n quote-service-ns -o wide
```

---

## Step 3: Inspect pod certificate

Let's look at the certificate inside the greeting-service pod. This was issued automatically by the cert-manager CSI driver from our cluster CA. Notice the SAN matches the in-cluster DNS name, and the cert is valid for both SSL server and SSL client use.

```bash
./scripts/inspect-cert.sh pod greeting-service
```

---

## Step 4: Hit the public endpoint

Now let's prove the full chain works - a request from the internet, through the ALB, to greeting-service, which then calls quote-service over mTLS internally.

```bash
curl -s https://greeting.fcc.ospatil.people.aws.dev/greeting | jq .
```

---

## Step 5: Prove mTLS is enforced

This is the key proof. We'll try to call quote-service directly WITHOUT presenting a client certificate. Watch the TLS handshake - the server will demand a cert, we won't provide one, and the connection will be rejected.

```bash
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n quote-service-ns \
  -- curl -svk --max-time 5 https://quote-service.quote-service-ns.svc.cluster.local:8443/quote
```

Key lines to highlight in the output:
- `Request CERT (13)` - server demands a client certificate
- `tlsv13 alert certificate required` - connection rejected

The greeting-service app call in step 3 succeeded because it presents its client cert via the Spring Boot client SSL bundle. Plain curl fails because it has nothing to present. That's mTLS in action.

---

## Step 6: Request and fetch dev certificate

Now let's set up for local development. We'll invoke the Lambda to issue a dev cert from our dev CA and store it in Secrets Manager, then pull it to the local machine.

```bash
./scripts/request-dev-cert.sh greeting-service
./scripts/fetch-dev-cert.sh greeting-service
```

---

## Step 7: Inspect dev certificate

Let's compare the dev cert with the pod cert from step 2. Notice: same SAN, same SSL server/client capabilities, but issued by the dev CA instead of the cluster CA. Both chain to the same root, so mutual trust works.

```bash
./scripts/inspect-cert.sh local greeting-service
```

---

## Step 8: Connect Telepresence and start intercept

Now we connect Telepresence to the cluster and set up a global intercept on greeting-service. This will route all traffic destined for the in-cluster greeting-service to our local machine instead.

```bash
telepresence connect -n greeting-service-ns
telepresence intercept greeting-service --port 8443:8443
```

---

## Step 9: Run local service with dev cert **[MANUAL]**

Please run this in a separate terminal - it starts the Spring Boot app locally with the dev cert:

```bash
./scripts/run-local.sh greeting-service
```

Wait for `Started GreetingApplication` in the log before proceeding.

---

## Step 10: Test - traffic routed to local service

The local greeting-service is now receiving traffic via Telepresence. It uses the dev cert for its server identity and presents it as a client cert when calling quote-service over mTLS. Let's test both paths.

Via the public ALB endpoint:

```bash
curl -s https://greeting.fcc.ospatil.people.aws.dev/greeting | jq .
```

Via cluster DNS with the CA cert:

```bash
curl -s --cacert .certs/greeting-service/ca.crt \
  https://greeting-service.greeting-service-ns.svc.cluster.local:8443/greeting | jq .
```

---

## Cleanup

Stop the intercept, disconnect Telepresence, remove local dev certs, and restart the deployment to remove the Telepresence traffic agent sidecar.

```bash
telepresence leave greeting-service
telepresence quit -s
rm -rf .certs/
kubectl rollout restart deployment/greeting-service -n greeting-service-ns
```

Also stop the local greeting-service in the other terminal (Ctrl+C).
