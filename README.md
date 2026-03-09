# How Telepresence Works

## Kubernetes

### Create cluster

1. Create cluster using eksctl - `eksctl create cluster -f eksctl-cluster.yaml`
1. Make the API server endpoint private - `eksctl utils update-cluster-vpc-config --cluster=auto-mode-private-access --private-access=true --public-access=false --approve`
1. Create a bastion server in one of the **private** subnets of the cluster. No need to configure a SSH key-pair or public IP for it. We'll connect to it using SSM session manager.

### Configure and connect to Kubernetes

1. Start port-forwarding session with bastion -
    `aws ssm start-session --target i-<instance-id> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters "host=<eks-cluster-id>.gr7.ca-central-1.eks.amazonaws.com,portNumber=443,localPortNumber=4443"`
1. Update kube config -
    `aws eks update-kubeconfig --name auto-mode-private-access --region ca-central-1 && kubectl config set-cluster arn:aws:eks:ca-central-1:<account-id>:cluster/auto-mode-private-access --insecure-skip-tls-verify=true --server=https://localhost:4443`

### Kubernetes resource creation

1. Create namespace for `service-a` - `kubectl create ns service-a-ns`
1. Create namespace for `service-b` - `kubectl create ns service-b-ns`
1. Create `service-b` resources - `kubectl apply -f b-manifest.yaml`
1. Create `service-a` resources - `kubectl apply -f a-manifest.yaml`

### Install telepresence

1. Install telepresence client on local machine using platform-specific mechanism -
   `brew install telepresenceio/telepresence/telepresence-oss`
1. Install Traffic manager in the cluster - `telepresence helm install`

### Telepresence

#### Setup

* Connect to traffic manager - `telepresence connect -n service-a-ns`
* Check the status - `telepresence status`
* List the deployments ready to be engaged - `telepresence list`
* Verify you can call services from local machine using in-cluster kubernetes DNS names - `curl service-a.service-a-ns:8080`

#### Usage - Global Intercept

This intercepts **all** traffic to service-a and routes it to your local machine.

* Intercept a service port - `telepresence intercept service-a-deployment --port 8080:8080`
  * Now we can run the local "service-a" application - `node local.js` and see the calls to the service being routed to our local machine. We can test it by running `curl service-a.service-a-ns:8080`.
  * This also demonstrates that our code running locally can call `service-b` which is running in the cluster.
* Stop proxying - `telepresence leave service-a-deployment`
* Stop local Telepresence Daemons - `telepresence quit -s`

#### Usage - Header-Based Routing (Personal Intercept)

This intercepts only requests matching a specific HTTP header, allowing multiple developers to work on the same service simultaneously without interfering with each other. Requires Telepresence >= 2.25.

* Start local service-a - `node local.js`
* Create a personal intercept with a header filter -
  `telepresence intercept service-a-deployment --port 8080:8080 --http-header x-dev=local`
* Test **with** header — traffic is routed to your local machine:
  `curl -H "x-dev: local" http://service-a.service-a-ns:8080`
  * Response: `"Hello from service-b! and Hello from local service-a!"`
* Test **without** header — traffic goes to the in-cluster service-a as normal:
  `curl http://service-a.service-a-ns:8080`
  * Response: `"Hello from service-b! and Hello from service-a!"`
* A second developer can intercept with a different header value without conflict:
  `telepresence intercept service-a-deployment --port 8080:8080 --http-header x-dev=dev2`
* Stop proxying - `telepresence leave service-a-deployment`
* Stop local Telepresence Daemons - `telepresence quit -s`

### Peeking under the hood

Refer to [Connectivity Analysis](./connectivity-analysis.md)

### Using Telepresence with Kyverno

Refer to [Telepresence and Kyverno](./telepresence-with-kyverno.md)

### mTLS with Service Meshes

* [East-West mTLS with Linkerd + Telepresence](./mtls-demo.md)
* [East-West mTLS with Istio Ambient + Telepresence](./istio-ambient-demo.md)
* [Bespoke Sidecar mTLS — Lightweight Alternative](./bespoke-sidecar-mtls.md)

#### Understanding the mTLS Encryption Boundary

Neither service mesh model provides true end-to-end encryption from app process to app process. Both encrypt the **network hop between nodes** — the segment where traffic is actually at risk — and terminate encryption at a proxy boundary.

```
Linkerd (sidecar per pod):
  app ──plain──▶ linkerd-proxy ══mTLS══▶ linkerd-proxy ──plain──▶ app
                 (same pod)              (same pod)
  └─── pod boundary ───┘                └─── pod boundary ───┘

Istio Ambient (ztunnel per node):
  app ──plain──▶ ztunnel ══════mTLS══════▶ ztunnel ──plain──▶ app
                 (same node)               (same node)
  └─── node boundary ───┘                 └─── node boundary ───┘
```

The unencrypted legs never leave their trust boundary:
- **Linkerd**: app ↔ sidecar is localhost within the same pod
- **Istio Ambient**: app ↔ ztunnel is local traffic within the same node

| | Unencrypted leg | Trust boundary | Implication |
|---|---|---|---|
| Linkerd sidecar | proxy ↔ app (same pod) | Pod | Attacker needs pod-level access |
| Istio Ambient | ztunnel ↔ app (same node) | Node | Attacker needs node-level access |

Istio Ambient's trust boundary is slightly wider (node vs pod), which is the trade-off for not needing sidecars. This is considered acceptable because Kubernetes itself trusts the node — kubelet already has access to all pod secrets on that node. Node-level access implies full compromise regardless of encryption.

#### Privileged Pod Risk and Mitigation

A privileged pod (or one with `hostNetwork: true`, `CAP_NET_RAW`, `CAP_NET_ADMIN`) running on the same node can sniff the unencrypted ztunnel ↔ app traffic, breaking Ambient's trust model. This also applies to Linkerd — a privileged pod can sniff traffic before it enters the sidecar. The attack surface is slightly wider with Ambient (node vs pod), but a privileged pod breaks both models.

**Mitigation: Pod Security Standards (PSA)** — built into Kubernetes 1.25+, no extra tooling needed:

```bash
kubectl label ns <namespace> \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

The `restricted` profile blocks `privileged: true`, `hostNetwork`, dangerous capabilities, and requires non-root containers. Enforce it on all application namespaces by default.

**For custom policies beyond pod security** (image allowlists, required labels, resource limits), layer [Kyverno](./telepresence-with-kyverno.md) or OPA Gatekeeper on top. PSA is the floor; policy engines handle everything else.

#### Linkerd vs Istio Ambient: Which to Choose?

| Aspect | Linkerd | Istio Ambient |
|---|---|---|
| Data plane model | Sidecar per pod (~20MB each) | ztunnel DaemonSet per node (~30MB each) |
| Mesh enrollment | Annotation + pod restart | Namespace label (instant, no restart) |
| Control plane size | ~250MB | ~1GB (istiod) |
| Certificate management | External (cert-manager required) | Built-in CA (istiod), external CA optional via istio-csr |
| L7 features | Built into sidecar (always available) | Requires waypoint proxy (on demand) |
| Ecosystem | Smaller, focused | Large (Kiali, Gateway API, multi-cluster, extensive policy model) |
| OSS release model | Edge releases only since Feb 2024; stable releases require Buoyant Enterprise | Stable releases backed by Google/Solo.io |
| Telepresence compatibility | Works in PERMISSIVE mode | Works in PERMISSIVE mode |

**When to pick Linkerd**: Small clusters where simplicity and minimal resource overhead matter most. Fewer moving parts, faster to learn and debug. Best when you just need mTLS without complex traffic policies.

**When to pick Istio Ambient**: Most other cases. The sidecar-less model closes Linkerd's main architectural advantage, while Istio offers a larger ecosystem, built-in CA, L7 extensibility, and stronger long-term OSS community momentum. The better default choice for production unless you have a specific reason to prefer Linkerd's simplicity.

**A note on Cilium Service Mesh**: Cilium offers eBPF-based mTLS at the kernel level — no sidecars or per-node proxies — with excellent performance. However, it requires Cilium as your CNI. It cannot layer on top of AWS VPC CNI or other CNIs for mesh features. If you're on EKS with VPC CNI and don't want to swap it out, Cilium's mesh isn't an option. If you're open to replacing VPC CNI, Cilium's [AWS ENI mode](https://docs.cilium.io/en/stable/network/concepts/ipam/eni/) preserves native VPC networking (routable pod IPs, security groups) while enabling mesh capabilities. Both Istio Ambient and Linkerd are CNI-agnostic and work alongside any CNI.