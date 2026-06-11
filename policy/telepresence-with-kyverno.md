# Telepresence with Kyverno

How to run Telepresence on a cluster whose pods are governed by strict Kyverno
security policies (non-root, dropped capabilities, read-only root filesystem,
seccomp, approved image registries).

## Why there is a conflict

Telepresence injects components that **inherently require elevated privileges**,
which is the exact opposite of what a hardened security policy enforces. There
are two distinct injected pieces, and they fail policy for different reasons:

| Injected component | Where it runs | Needs | Why |
|---|---|---|---|
| **traffic-agent** (sidecar) | the workload pod's `containers[]` | `NET_ADMIN`, `allowPrivilegeEscalation: true`, writable root FS, `runAsNonRoot: false` | Proxies/relays intercepted traffic |
| **tel-agent-init** (init container) | the workload pod's `initContainers[]` | `runAsUser: 0` (root) + `NET_ADMIN` | Programs `iptables`/`nf_tables` rules to redirect traffic to the agent |
| **traffic-manager** | its own namespace (`ambassador` by default) | relaxed pod/container securityContext | Its image/securityContext don't match a `restricted`-style policy |

A policy such as `require-security-context` (enforcing `runAsNonRoot: true`,
`runAsUser >= 1000`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
`readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`) will **reject
all three**. There is no securityContext that keeps the agent functional *and*
satisfies non-root — so the agent containers must be **exempted**, not "fixed".

> **Important:** A Kyverno `containers[]` pattern does **not** also validate
> `initContainers[]`. So a typical `require-security-context` policy catches the
> traffic-agent sidecar but is blind to `tel-agent-init`. The init container's
> root requirement is therefore an **OS-level** problem (iptables needs root),
> not necessarily a Kyverno rejection — but a policy that *does* validate
> `initContainers[]` will reject it too, and then it needs exempting as well.

## Solution overview

Two independent pieces are required:

1. **Relax the injected agents' securityContext** via Telepresence Helm values so
   the agent/init containers are *created* with the privileges they need.
2. **Exempt those pods from the policies** so Kyverno *admits* them.

Both are necessary: (1) makes the containers functional, (2) makes them pass
admission.

---

## 1. Telepresence Helm values (agent securityContext)

Two separate keys — one per injected container. `agent.securityContext` covers
**only the sidecar**; the init container has its own `agent.initSecurityContext`
(added in chart 2.22.0). Setting only the first is the most common mistake and
leaves `tel-agent-init` crash-looping with `iptables: Permission denied (you
must be root)`.

```yaml
agent:
  # traffic-agent sidecar
  securityContext:
    allowPrivilegeEscalation: true
    readOnlyRootFilesystem: false
    runAsNonRoot: false
    capabilities:
      add: [NET_ADMIN]
      drop: []
  # tel-agent-init init container — MUST run as root to program iptables
  initSecurityContext:
    runAsUser: 0
    runAsNonRoot: false
    allowPrivilegeEscalation: true
    capabilities:
      add: [NET_ADMIN]
      drop: []
```

> **Note:** Only `NET_ADMIN` is required on current versions (2.2x). Older guides
> list `SYS_PTRACE` as well — it is no longer needed.

### Alternative: run without the init container

The init container is only needed for Services whose `targetPort` is a **port
number**. If the Service's `targetPort` references a **port name** instead,
Telepresence routes via a port-rename mechanism and **no init container (and no
iptables/NET_ADMIN/root) is required**. You can disable it entirely:

```yaml
agent:
  initContainer:
    enabled: false   # init-less; requires NAMED Service targetPorts
```

Trade-off: every interceptable Service must use a **named** `targetPort` (e.g.
`targetPort: http`, not `targetPort: 8080`). Numeric-port Services cannot be
intercepted in this mode. This is the right choice for environments that forbid
`NET_ADMIN` outright (e.g. OpenShift), at the cost of requiring named ports
cluster-wide.

---

## 2. Exempting the pods from Kyverno

Two mechanisms exist. Choose based on who owns exemptions and how many namespaces
are involved.

### Option A — `PolicyException` object (recommended, extensible)

A standalone object that points at policies from outside them. Scope it with a
**label selector** on the marker the agent-injector stamps on every injected pod
— this covers **all current and future intercepted workloads in any namespace**
with no per-namespace edits:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: telepresence-agent-exception
  namespace: kyverno            # see "exception namespace" note below
spec:
  exceptions:
  - policyName: require-security-context
    ruleNames: [require-security-context-constraints, require-pod-security-context]
  match:
    any:
    # (1) every pod the injector mutates, in any namespace
    - resources:
        kinds: [Pod]
        selector:
          matchLabels:
            telepresence.io/workloadEnabled: "true"
    # (2) the traffic-manager itself (not labeled by the injector)
    - resources:
        kinds: [Pod]
        namespaces: [ambassador]
```

The injector stamps these labels on injected pods (verified on 2.28):
`telepresence.io/workloadEnabled: "true"`, `telepresence.io/workloadKind`,
`telepresence.io/workloadName`. `workloadEnabled` is the stable, namespace-
agnostic marker to match on.

**Prerequisites — PolicyExceptions are often disabled by default:**

```yaml
# Kyverno Helm values
features:
  policyExceptions:
    enabled: true        # maps to --enablePolicyException (default: false!)
    namespace: kyverno   # maps to --exceptionNamespace; restricts WHERE exceptions
                         # may be created. Lock to an admin-only namespace so app
                         # teams cannot self-exempt from their own namespaces.
```

If `--enablePolicyException=false` (the default), **PolicyException objects are
silently ignored** — a common source of "my exception isn't working".

### Option B — in-policy `exclude` blocks

Add the carve-out directly inside each ClusterPolicy's `exclude:`. Works with
PolicyExceptions disabled and keeps all exemptions inside admin-owned policy
definitions, but you exempt by **namespace list** — which must be maintained and
the policy redeployed for every new namespace. Fine for a handful of namespaces;
doesn't scale to many.

```yaml
rules:
- name: require-security-context-constraints
  exclude:
    any:
    - resources:
        namespaces: [ambassador]   # + every intercept-enabled namespace
```

### A/B comparison

| | PolicyException (A) | in-policy `exclude` (B) |
|---|---|---|
| Lives in | separate object | inside the ClusterPolicy |
| Scales to many namespaces | ✅ via label selector | ❌ hand-maintained namespace list |
| Needs `--enablePolicyException=true` | yes | no |
| Self-exemption risk | controlled via `--exceptionNamespace` | none (policy is admin-owned) |

---

## Security caveats (read before deploying)

- **Exemptions are pod-scoped, not container-scoped.** Exempting an injected pod
  from `require-security-context` also stops enforcing it on that pod's
  **application container** while the agent is present. Matching on the injector
  label keeps this as tight as possible (only actually-injected pods), but you
  should **gate intercepts to non-production namespaces**.
- **The injector label is an operational scope, not a hard boundary** — a pod
  author could set `telepresence.io/workloadEnabled` themselves. The real control
  over *who can create exemptions* is `--exceptionNamespace` (Option A) or
  policy ownership (Option B), not the label.
- **Keep image policy strict.** The agent images come from
  `ghcr.io/telepresenceio/*`. Prefer mirroring them into your approved registry
  and keeping `restrict-image-registries` enforced, rather than broadly allowing
  a public registry.

## Operational notes

- **Large clusters:** `telepresence connect` maps *all* namespaces into the local
  DNS/NAT by default, which can time out the root daemon
  (`failed to connect to root daemon: context deadline exceeded`) on clusters
  with hundreds of namespaces. Scope it: `telepresence connect --namespace <ns>
  --mapped-namespaces <ns>`.
- **The root daemon needs local privileges** (creates a TUN device) — run
  `telepresence connect` from an interactive shell that can prompt for it.

## Validation

```bash
# traffic-manager healthy
kubectl get pods -n ambassador

# connect (scoped) and intercept
telepresence connect --namespace <ns> --mapped-namespaces <ns>
telepresence intercept <deployment> --port <local>:<remote>

# the injected pod should reach 2/2 (app + traffic-agent) with the init
# container Completed (not CrashLoopBackOff)
kubectl get pod -n <ns> -l app=<label>
kubectl get pod -n <ns> <pod> -o jsonpath='{range .status.initContainerStatuses[*]}{.name}: {.state}{"\n"}{end}'
```

Expected securityContexts on a successful intercept:

```yaml
# application container — still policy-compliant (unchanged by injection)
allowPrivilegeEscalation: false
runAsNonRoot: true
capabilities: { drop: [ALL] }
readOnlyRootFilesystem: true
seccompProfile: { type: RuntimeDefault }

# traffic-agent sidecar — relaxed via agent.securityContext
allowPrivilegeEscalation: true
runAsNonRoot: false
capabilities: { add: [NET_ADMIN] }
readOnlyRootFilesystem: false

# tel-agent-init init container — root, via agent.initSecurityContext
runAsUser: 0
capabilities: { add: [NET_ADMIN] }
```
