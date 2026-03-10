# Telepresence with Kyverno

## Problem Statement

Telepresence proxying fails in Kubernetes clusters with Kyverno security policies because the injected traffic-agent sidecar requires elevated privileges (SYS_PTRACE, NET_ADMIN capabilities, privilege escalation, and root filesystem access) that conflict with Kyverno's strict security context enforcement.

## Solution

### 1. Required Kyverno Policy Exclusions

The `ambassador` namespace (where traffic-manager is installed) requires exclusions from **3 specific policy rules**:

* **Policy:** `require-security-context-constraints`
* **Policy:** `require-pod-security-context`
* **Policy:** `restrict-image-registries`
  *Required for:* Traffic-manager to pull images from GitHub Container Registry (`ghcr.io`)

### 2. Kyverno Policy Configuration

Add ambassador namespace exclusions to the required policies:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-security-context
spec:
  validationFailureAction: Enforce
  background: false
  rules:
  - name: require-security-context-constraints
    exclude:
      any:
      - resources:
          namespaces:
          - ambassador  # Telepresence namespace
  - name: require-pod-security-context
    exclude:
      any:
      - resources:
          namespaces:
          - ambassador  # Telepresence namespace
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  rules:
  - name: validate-registries
    exclude:
      any:
      - resources:
          namespaces:
          - ambassador  # Telepresence namespace
```

### 3. Telepresence Configuration

Create a minimal Helm values file to override agent security context:

**File: `telepresence-agent-security.yaml`**

```yaml
# Minimal agent security context override for Kyverno compatibility
agent:
  securityContext:
    allowPrivilegeEscalation: true
    readOnlyRootFilesystem: false
    runAsNonRoot: false
    capabilities:
      add:
      - SYS_PTRACE
      - NET_ADMIN
      drop: []
```

### 4. Installation Command

Install Telepresence using the telepresence CLI command with custom values:

```bash
telepresence helm install --values telepresence-agent-security.yaml
```

## Validation Commands

### 1. Verify Installation

```bash
# Check traffic-manager is running
kubectl get pods -n ambassador

# Connect to Telepresence
telepresence connect -n <your-namespace>
```

### 2. Test Intercept

```bash
# Create an intercept
telepresence intercept <deployment-name> --port <port>

# Verify pod has traffic-agent injected (should show 2/2 containers)
kubectl get pods -n <your-namespace>
```

### 3. Validate Security Contexts

```bash
# Check main application container security context (should be Kyverno-enforced)
kubectl get pod -n <namespace> -l app=<app-label> -o yaml | grep -A 20 -B 5 securityContext

# Verify both containers have appropriate security contexts
kubectl get pod -n <namespace> -l app=<app-label> -o jsonpath='{.items[0].spec.containers[*].name}'
```

## Results Verification

After implementing this solution, the security contexts should show:

### Main Application Container (Kyverno Enforced)

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  readOnlyRootFilesystem: true
  runAsGroup: 3000
  runAsNonRoot: true
  runAsUser: 1000
  seccompProfile:
    type: RuntimeDefault
```

### Traffic-Agent Container (Telepresence Override)

```yaml
securityContext:
  allowPrivilegeEscalation: true
  capabilities:
    add: [SYS_PTRACE, NET_ADMIN]
  readOnlyRootFilesystem: false
  runAsNonRoot: false
```

### Pod Security Context (Kyverno Enforced)

```yaml
securityContext:
  fsGroup: 2000
  runAsGroup: 3000
  runAsNonRoot: true
  runAsUser: 1000
  seccompProfile:
    type: RuntimeDefault
```

## Key Benefits

✅ **No PolicyExceptions Required** - Clean, targeted solution without broad policy exemptions

✅ **Kyverno Policies Remain Enforced** - Main application containers still get full security context validation

✅ **Principle of Least Privilege** - Only traffic-agent gets necessary relaxed permissions

✅ **Minimal Configuration** - Reproducible configuration through single values file with only essential overrides
