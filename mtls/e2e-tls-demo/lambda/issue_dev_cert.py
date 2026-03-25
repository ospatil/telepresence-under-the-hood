import json
import boto3
import os
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from datetime import datetime, timezone

pca = boto3.client("acm-pca")
sm = boto3.client("secretsmanager")

DEV_CA_ARN = os.environ["DEV_CA_ARN"]
ROOT_CA_ARN = os.environ["ROOT_CA_ARN"]
VALIDITY_DAYS = int(os.environ.get("VALIDITY_DAYS", "30"))
SECRET_PREFIX = os.environ.get("SECRET_PREFIX", "e2e-tls-demo/dev-certs")


def handler(event, context):
    service_name = event.get("service_name")
    namespace = event.get("namespace", f"{service_name}-ns")
    force = event.get("force", False)

    if not service_name:
        return {"statusCode": 400, "body": "service_name is required"}

    san = f"{service_name}.{namespace}.svc.cluster.local"
    secret_name = f"{SECRET_PREFIX}/{service_name}"

    # Check existing cert
    if not force:
        try:
            existing = sm.get_secret_value(SecretId=secret_name)
            cert_data = json.loads(existing["SecretString"])
            cert = x509.load_pem_x509_certificate(cert_data["tls.crt"].encode())
            if cert.not_valid_after_utc > datetime.now(timezone.utc):
                return {
                    "statusCode": 200,
                    "body": f"Valid cert exists for {service_name}, expires {cert.not_valid_after_utc.isoformat()}. Use force=true to re-issue.",
                }
        except sm.exceptions.ResourceNotFoundException:
            pass  # No existing secret, proceed

    # Generate private key
    key = ec.generate_private_key(ec.SECP256R1())
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ).decode()

    # Create CSR
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, service_name)]))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(san)]), critical=False)
        .sign(key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM)

    # Issue cert from dev CA
    issue_resp = pca.issue_certificate(
        CertificateAuthorityArn=DEV_CA_ARN,
        Csr=csr_pem,
        SigningAlgorithm="SHA256WITHECDSA",
        Validity={"Value": VALIDITY_DAYS, "Type": "DAYS"},
    )

    waiter = pca.get_waiter("certificate_issued")
    waiter.wait(
        CertificateAuthorityArn=DEV_CA_ARN,
        CertificateArn=issue_resp["CertificateArn"],
    )

    cert_resp = pca.get_certificate(
        CertificateAuthorityArn=DEV_CA_ARN,
        CertificateArn=issue_resp["CertificateArn"],
    )

    # Get root CA cert for truststore
    root_resp = pca.get_certificate_authority_certificate(
        CertificateAuthorityArn=ROOT_CA_ARN
    )

    # Bundle leaf cert + intermediate (dev CA cert) for full chain
    leaf = cert_resp["Certificate"].rstrip()
    chain = cert_resp["CertificateChain"].rstrip()
    full_chain = leaf + "\n" + chain

    secret_value = json.dumps({
        "tls.crt": full_chain,
        "tls.key": key_pem,
        "ca.crt": root_resp["Certificate"],
    })

    # Store in Secrets Manager
    try:
        sm.put_secret_value(SecretId=secret_name, SecretString=secret_value)
    except sm.exceptions.ResourceNotFoundException:
        sm.create_secret(Name=secret_name, SecretString=secret_value)

    cert = x509.load_pem_x509_certificate(cert_resp["Certificate"].encode())

    return {
        "statusCode": 200,
        "body": f"Cert issued for {service_name} (SAN: {san}), expires {cert.not_valid_after_utc.isoformat()}",
        "secret_name": secret_name,
    }
