# Bespoke Sidecar mTLS — Lightweight Alternative to Service Meshes

Instead of adopting a full service mesh (Istio, Linkerd), you can build a lightweight mTLS sidecar using a standard reverse proxy. This gives you east-west (service-to-service) and north-south (ingress-to-pod) encryption with minimal overhead and full control.

## Sidecar Proxy Options

| Aspect | nginx | HAProxy | Envoy |
|---|---|---|---|
| Image size | ~10MB (alpine) | ~20MB | ~60-80MB |
| Memory (idle) | ~2-5MB | ~5-10MB | ~20-30MB |
| Memory (under load) | ~10-20MB | ~15-30MB | ~50-100MB |
| TLS termination | Yes | Yes | Yes |
| mTLS (client certs) | Yes | Yes | Yes |
| Hot reload | `nginx -s reload` (brief) | Seamless via `master-worker` mode | Native via xDS/SDS |
| L7 routing | Basic (location blocks) | Advanced (ACLs, maps) | Most advanced (filters, Lua, Wasm) |
| Health checks | Basic | Advanced (agent checks, DNS) | Advanced |
| Observability | Access logs, basic metrics | Prometheus exporter, detailed stats | Rich built-in metrics |
| Config model | Static files | Static files | Static or dynamic (xDS API) |

### When to use which

- **nginx**: Just need TLS termination + mTLS + basic proxying. Lightest option, most widely understood.
- **HAProxy**: Need more sophisticated load balancing, health checking, or routing than nginx. Better built-in stats without needing commercial nginx Plus.
- **Envoy**: Need dynamic configuration (xDS), advanced L7 features (Wasm, gRPC-native), or SDS for cert rotation without file watches. At this point, you're approaching "just use a service mesh" territory.

## Certificate Management Approaches

The main challenge with bespoke sidecars is managing short-lived certificate issuance and renewal. Four approaches, from simplest to most flexible:

### 1. cert-manager CSI Driver (recommended)

[cert-manager csi-driver](https://cert-manager.io/docs/usage/csi-driver/) mounts short-lived certs directly into pods as ephemeral volumes. No init container, no renewal agent — cert-manager handles issuance and renewal transparently.

```yaml
volumes:
  - name: tls
    csi:
      driver: csi.cert-manager.io
      readOnly: true
      volumeAttributes:
        csi.cert-manager.io/issuer-name: my-issuer
        csi.cert-manager.io/dns-names: ${POD_NAME}.${POD_NAMESPACE}.svc.cluster.local
        csi.cert-manager.io/duration: 1h
        csi.cert-manager.io/renew-before: 15m
```

The sidecar proxy reads certs from the mounted path. Works with any cert-manager issuer including `aws-privateca-issuer` for production (see [AWS Private CA notes in the Linkerd demo](./linkerd/mtls-demo.md#production-alternative-aws-private-ca)).

**Pros**: zero custom code for cert management, battle-tested, auto-renewal built in
**Cons**: requires cert-manager + CSI driver installed in cluster

### 2. SPIFFE/SPIRE

[SPIRE](https://spiffe.io/) is purpose-built for workload identity. It issues short-lived X.509 SVIDs (SPIFFE Verifiable Identity Documents) and handles rotation automatically.

- SPIRE agent runs as a DaemonSet (similar to Istio's ztunnel)
- Sidecar uses the SPIFFE Workload API (Unix domain socket) to fetch certs
- Certs are typically 1-hour TTL, auto-rotated by the agent
- Supports AWS PCA as an upstream CA

**Pros**: designed for workload identity, strong attestation (node + pod level), CNCF graduated
**Cons**: another system to operate, more complex than cert-manager for simple cases

### 3. Init Container + Renewal Sidecar

DIY approach — an init container fetches the initial cert, and a lightweight sidecar handles renewal:

- Init container calls cert-manager API (or AWS PCA directly), writes cert to shared `emptyDir` volume
- Renewal sidecar watches cert expiry and re-fetches before expiration
- Proxy sidecar reads certs from the shared volume, reloads on change (`inotifywait` + `nginx -s reload`)

**Pros**: full control, no CSI driver dependency
**Cons**: custom code to maintain, reimplements what cert-manager CSI driver already does

### 4. Envoy SDS (if using Envoy)

If using Envoy as the sidecar, it has built-in SDS (Secret Discovery Service) support. Point it at SPIRE's Workload API or an SDS server backed by cert-manager. Envoy handles cert rotation natively without file watches or reloads.

**Pros**: no file-based cert management, hot reload built in
**Cons**: only works with Envoy, heavier footprint

## Advantage Over Service Meshes: Unified North-South + East-West TLS

Service meshes typically handle east-west (service-to-service) mTLS only. With a bespoke proxy sidecar, you can terminate TLS for both traffic directions:

- **East-west**: mTLS between services within the cluster
- **North-south**: TLS termination for traffic entering from outside (ingress → pod)

One consistent TLS layer for all traffic paths, managed by the same cert pipeline (cert-manager + AWS PCA). With Istio/Linkerd, you'd need a separate ingress gateway or waypoint proxy for north-south TLS.

## Trade-offs vs Service Meshes

| | Bespoke sidecar | Service mesh (Istio/Linkerd) |
|---|---|---|
| mTLS | Manual config per service | Automatic, mesh-wide |
| Footprint | Minimal (nginx ~5MB idle) | Higher (control plane + data plane) |
| Observability | DIY (access logs, Prometheus exporters) | Built-in (topology, golden metrics, dashboards) |
| Traffic policies | Manual proxy config | Declarative CRDs (retries, circuit breaking, traffic splitting) |
| North-south TLS | Same sidecar handles both | Separate ingress gateway needed |
| Operational complexity | Lower infrastructure, higher per-service config | Higher infrastructure, lower per-service config |
| Best for | Small number of services, teams wanting full control | Large service counts, teams wanting automation |

## Operational Considerations

### Sidecar Injection

Service meshes inject sidecars automatically via mutating webhooks. For bespoke sidecars:
- **Manual**: add the sidecar container to every deployment YAML — simple but doesn't scale
- **Kyverno mutating policy**: auto-inject the sidecar + volume mounts on pod creation (see [Telepresence and Kyverno](../policy/telepresence-with-kyverno.md)). More maintainable than a custom webhook
- **Custom mutating admission webhook**: most flexible but more code to maintain

### Certificate Reload Without Downtime

When certs rotate on disk, the proxy needs to pick them up:
- **nginx**: doesn't watch files — needs an explicit `nginx -s reload`. Requires a small process (`inotifywait` loop or cron) to trigger it
- **HAProxy**: `master-worker` mode handles this more gracefully
- **Envoy**: native SDS, no file watching needed

### mTLS Policy Enforcement and Telepresence Compatibility

Service meshes let you declaratively set STRICT vs PERMISSIVE mTLS per namespace/service. With bespoke nginx, you configure `ssl_verify_client` per sidecar:
- `on` (strict): demands a client cert — **Telepresence intercepts will be rejected** since the local machine doesn't present a client cert
- `optional` (permissive): accepts both mTLS and plain HTTP — **Telepresence works**, same as Istio/Linkerd in PERMISSIVE mode

With a service mesh, switching modes is a one-line policy change. With bespoke nginx, you need to:
1. Change `ssl_verify_client` from `on` to `optional`
2. Reload the sidecar (`nginx -s reload`)
3. Switch it back after development

For practical use, automate this with an env-based toggle and Kyverno mutation:

**Namespace label** signals the mode:
```bash
kubectl label ns service-a-ns mtls-mode=permissive   # dev — Telepresence works
kubectl label ns service-a-ns mtls-mode=strict        # prod
```

**nginx config** uses `envsubst` to read the mode from an environment variable:
```nginx
server {
    listen 8443 ssl;
    ssl_certificate /certs/tls.crt;
    ssl_certificate_key /certs/tls.key;
    ssl_client_certificate /certs/ca.crt;
    ssl_verify_client ${MTLS_VERIFY};

    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
```

**Sidecar container** defaults to `optional` (permissive):
```yaml
containers:
  - name: nginx-mtls
    image: nginx:alpine
    command: ["/bin/sh", "-c", "envsubst '${MTLS_VERIFY}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"]
    env:
      - name: MTLS_VERIFY
        value: "optional"
```

**Kyverno policy** overrides to `on` (strict) for prod namespaces:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: set-mtls-mode
spec:
  rules:
    - name: strict-for-prod
      match:
        resources:
          kinds: [Pod]
          namespaceSelector:
            matchLabels:
              mtls-mode: strict
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): nginx-mtls
                env:
                  - name: MTLS_VERIFY
                    value: "on"
```

The flow:
```
Namespace label: mtls-mode=permissive
  → Kyverno: no mutation (default "optional" stays)
  → nginx: ssl_verify_client optional → Telepresence works ✓

Namespace label: mtls-mode=strict
  → Kyverno: mutates MTLS_VERIFY to "on"
  → nginx: ssl_verify_client on → Telepresence rejected (no client cert) ✗
```

To toggle, flip the namespace label and restart pods. No config file editing, no per-service changes.

### Observability Gap

Service meshes provide golden metrics (latency, error rate, throughput) and topology maps automatically. With bespoke sidecars:
- You get access logs and basic metrics (nginx `stub_status` or Prometheus exporter)
- No automatic distributed tracing or service topology
- No mTLS status visibility ("which connections are encrypted right now?")

### Certificate Identity and Authorization

Service meshes tie certs to workload identity (SPIFFE IDs) and support authorization policies ("service-a can call service-b but not service-c"). With bespoke nginx:
- mTLS authenticates the connection but doesn't provide fine-grained authorization
- You'd need to inspect client cert CN/SAN in nginx config with `map`/`if` blocks per service — brittle at scale

### Upgrade and Patching

When a proxy CVE drops:
- **Service mesh**: update the control plane, sidecars roll automatically
- **Bespoke**: update the sidecar image across all deployments and trigger rollouts yourself

### Summary

| Concern | Service mesh | Bespoke sidecar |
|---|---|---|
| Sidecar injection | Automatic (webhook) | Manual or Kyverno policy |
| Cert reload | Transparent | You own it (inotifywait, cron) |
| mTLS policy (strict/permissive) | Declarative CRDs | Per-sidecar nginx config |
| Telepresence compatibility | PERMISSIVE mode toggle | Manual `ssl_verify_client` change per sidecar |
| Observability | Built-in golden metrics, topology | DIY (access logs, exporters) |
| Authorization | Identity-based policies | Manual cert CN/SAN inspection |
| Patching | Control plane update rolls sidecars | Manual image update + rollout |

None of these are blockers — they're operational costs you accept in exchange for simplicity and smaller footprint. The inflection point is when you find yourself building automation for injection, reload, policy, and observability — at that point you've effectively built a service mesh and should just adopt one.

## Recommendation

For a PoC: start with **nginx + cert-manager CSI driver**. It's the lightest combination with zero custom cert management code. If you outgrow nginx's routing capabilities, swap to HAProxy. If you need dynamic config or find yourself building too much automation around the sidecar, that's the signal to adopt a service mesh instead.
