# Telepresence Network Connectivity Analysis

## Overview

This document analyzes how Telepresence establishes connectivity to a private EKS cluster through AWS SSM port forwarding. The setup enables local development against remote Kubernetes services with transparent DNS resolution and network routing.

From Telepresence documentation:

*How does Telepresence connect and tunnel into the Kubernetes cluster?
The connection between your laptop and cluster is established by using the kubectl port-forward machinery (though without actually spawning a separate program) to establish a TLS encrypted connection to Telepresence Traffic Manager and Traffic Agents in the cluster, and running Telepresence's custom VPN protocol over that connection.*

> Note: PIDs and higher port numbers being used by Telepresence will change every session. The TUN interface name will also vary from time to time.

## High-Level Architecture

```sh
Local Application
↓ (DNS Query)
127.0.0.1:51011 (Telepresence DNS Server)
↓ (Kubernetes API Query)
127.0.0.1:59211/59215 → 127.0.0.1:4443 (SSM Tunnel) → EKS API Server
↓ (Service Resolution)
Returns cluster-internal IPs for seamless local-to-remote communication

Local Application Traffic
↓ (Network Traffic to Cluster IPs)
utun6 TUN Interface (10.100.0.0/16, 192.168.189.0/24)
↓ (Traffic Routing)
Telepresence Daemon (Root Process)
↓ (Encrypted Tunnel)
SSM Session → EKS Cluster Network
```

## Telepresence Process Architecture

Telepresence runs multiple processes with different responsibilities for security and functionality separation:

### Process Details

1. **PID 56750 - Connector Process** (`telepresence connector-foreground`)
   - Runs as user account
   - Handles connection to Kubernetes cluster
   - Manages intercepts and traffic routing logic
   - Communicates with Traffic Manager in cluster

2. **PID 56908 - Sudo Wrapper**
   - `sudo` process that elevates privileges to start daemon
   - Parent process that spawns the actual daemon

3. **PID 56909 - Daemon Process** (`telepresence daemon-foreground`)
   - Runs with root privileges (child of sudo process)
   - Handles low-level networking operations requiring root access
   - Manages DNS resolution and traffic interception at system level
   - Creates and manages TUN device for network traffic

### Process Hierarchy

```sh
PID 56908 (sudo wrapper)
└── PID 56909 (daemon - root privileges)

PID 56750 (connector - user privileges)
```

### Why Multiple Processes?

- **Security separation**: Connector runs as user while only daemon runs as root, minimizing privileged attack surface
- **Network requirements**: Daemon needs root privileges to modify system networking (DNS, routing, TUN devices)
- **Cluster communication**: Connector handles Kubernetes API interactions without elevated privileges
- **Process isolation**: Component failures don't necessarily bring down the entire system

## AWS SSM Port Forwarding Foundation

### SSM Session Details

**Process:** `session-manager-plugin` (PID 25489)

- External connection to AWS SSM: `<local-ip>:54572->15.156.212.201:443`
- Local port forwarding: Listening on `127.0.0.1:4443`
- Target: EKS API server `<eks-cluster-id>.gr7.ca-central-1.eks.amazonaws.com:443`
- EC2 Instance: `i-<instance-id>` (bastion/jump host)
- Region: `ca-central-1`

### Command Used

```sh
aws ssm start-session \
  --target i-<instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters host="<eks-cluster-id>.gr7.ca-central-1.eks.amazonaws.com",portNumber="443",localPortNumber="4443" \
  --region ca-central-1
```

### Connection Flow

```sh
Local Machine -> SSM Session (port 4443) -> EC2 Instance -> EKS API Server
     ↑
Telepresence connects to localhost:4443
```

## Telepresence API Connections

**Process:** `telepresence connector-foreground` (PID 56750)

### Multiple API Connections to SSM Tunnel

- `127.0.0.1:59211->127.0.0.1:4443`
- `127.0.0.1:59215->127.0.0.1:4443`

### Purpose of Multiple Connections

#### 1. Primary API Connection (59211)

- Main Kubernetes API operations
- Cluster discovery, resource queries, authentication
- Watching for changes in deployments and services

#### 2. Secondary API Connection (59215)

- Traffic Manager communication
- Telepresence-specific operations like traffic routing
- Monitoring intercept status and managing traffic agents

### Connection Architecture

```sh
Telepresence Process (PID 56750)
├── Port 59211 → localhost:4443 → SSM Tunnel → EKS API (Main API operations)
└── Port 59215 → localhost:4443 → SSM Tunnel → EKS API (Traffic Manager ops)
```

## TUN Interface Configuration

**Telepresence TUN Interface:** `utun6`

### Interface Details

```sh
utun6: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
 inet 10.100.0.0 --> 10.100.0.1 netmask 0xffff0000
 inet 192.168.189.0 --> 192.168.189.1 netmask 0xffffff00
```

### Routing Table Entries

```sh
10.100/16          10.100.0.1         UGCS                utun6
10.100.0.1         10.100.0.0         UH                  utun6
192.168.189        192.168.189.1      UGCS                utun6
192.168.189.1      192.168.189.0      UH                  utun6
```

### Managed Subnets

From Telepresence status, the TUN interface manages:

- `10.100.0.0/16` - Kubernetes pod network
- `192.168.189.0/24` - Kubernetes service network

### TUN Interface Purpose

The `utun6` interface allows Telepresence to:

- Route traffic destined for Kubernetes cluster's pod networks
- Handle service networks for seamless service-to-service communication
- Intercept and redirect traffic between local machine and cluster
- Enable transparent network connectivity to remote cluster resources

## DNS Resolution System

### Telepresence DNS Server

**Process:** `telepresence daemon-foreground` (PID `56909`, running as root)
**Connection:** `UDP 127.0.0.1:51011`

Port `51011` is used by Telepresence's local DNS server to resolve Kubernetes service names and cluster-internal domains.

### DNS Resolver Configuration Files

Telepresence creates multiple resolver files in `/etc/resolver/` that tell macOS to use `127.0.0.1:51011` for specific domains:

```sh
/etc/resolver/telepresence.ambassador
/etc/resolver/telepresence.cluster.local
/etc/resolver/telepresence.default
/etc/resolver/telepresence.kube-public
/etc/resolver/telepresence.service-a-ns
/etc/resolver/telepresence.service-b-ns
/etc/resolver/telepresence.svc
/etc/resolver/telepresence.tel2-search
```

### Sample Resolver Configuration

`/etc/resolver/telepresence.service-a-ns`:

```sh
# Generated by telepresence
port 51011
domain service-a-ns
nameserver 127.0.0.1
search service-a-ns
```

`/etc/resolver/telepresence.cluster.local`:

```sh
# Generated by telepresence
port 51011
domain cluster.local
nameserver 127.0.0.1
```

### DNS Resolution Flow

```sh
Local DNS Query (e.g., service-a.service-a-ns.svc.cluster.local)
↓
macOS resolver checks /etc/resolver/telepresence.service-a-ns
↓
Routes query to 127.0.0.1:51011 (Telepresence DNS server)
↓
Telepresence daemon queries Kubernetes API via SSM tunnel (port 4443)
↓
Returns cluster-internal IP addresses
```

## Current Telepresence Status

```sh
OSS User Daemon: Running
  Version           : 2.24.0
  Status            : Connected
  Kubernetes server : https://localhost:4443
  Kubernetes context: arn:aws:eks:ca-central-1:<account-id>:cluster/auto-mode-private-access
  Namespace         : service-a-ns
  Manager namespace : ambassador
  Mapped namespaces : [ambassador default kube-public service-a-ns service-b-ns]

OSS Root Daemon: Running
  Version: v2.24.0
  DNS    :
    Local address   : 127.0.0.1:51011
    Exclude suffixes: [.com .io .net .org .ru]
    Include suffixes: []
    Timeout         : 4s
  Subnets: (2 subnets)
    - 10.100.0.0/16
    - 192.168.189.0/24

OSS Traffic Manager: Connected
  Version      : v2.24.0
  Traffic Agent: ghcr.io/telepresenceio/tel2:2.24.0
```

### Available Services

```sh
deployment service-a-deployment: ready to engage (traffic-agent not yet installed)
```

## Network Connections Summary

### Relevant Network Connections (SSM & Telepresence Only)

```
session-m 25489 <user>   14u  IPv4 <handle>      0t0  TCP <local-ip>:54572->15.156.212.201:443 (ESTABLISHED)
session-m 25489 <user>   21u  IPv4 <handle>      0t0  TCP 127.0.0.1:4443 (LISTEN)
session-m 25489 <user>   22u  IPv4 <handle>      0t0  TCP 127.0.0.1:4443->127.0.0.1:59211 (ESTABLISHED)
session-m 25489 <user>   23u  IPv4 <handle>      0t0  TCP 127.0.0.1:4443->127.0.0.1:59215 (ESTABLISHED)
session-m 25489 <user>   25u  IPv4 <handle>      0t0  TCP 127.0.0.1:4443->127.0.0.1:59229 (ESTABLISHED)
teleprese 56750 <user>   21u  IPv4 <handle>      0t0  TCP 127.0.0.1:59211->127.0.0.1:4443 (ESTABLISHED)
teleprese 56750 <user>   22u  IPv4 <handle>      0t0  TCP 127.0.0.1:59215->127.0.0.1:4443 (ESTABLISHED)
teleprese 56909 root     20u  IPv4 <handle>      0t0  UDP 127.0.0.1:51011
```

## Discovery Commands Reference

### Network Detection Commands Used

1. **Show all established connections:**

   ```sh
   lsof -i -P -n | grep ESTABLISHED
   ```

2. **Filter for session-manager connections:**

   ```sh
   lsof -i -P -n | grep session-m
   ```

3. **Filter for telepresence connections:**

   ```sh
   lsof -i -P -n | grep teleprese
   ```

4. **Get telepresence process details:**

   ```sh
   ps aux | grep telepresence
   ps -p 56909,56750,56908 -o pid,ppid,command
   ```

5. **Check TUN interfaces:**

   ```sh
   ifconfig | grep -A 5 -B 1 tun
   netstat -rn | grep -E "(10\.|192\.168\.|utun)"
   ```

6. **Check specific daemon process network connections:**

   ```sh
   sudo lsof -p <daemon-pid> -i -P -n
   ```

7. **List DNS resolver files:**

   ```sh
   ls -la /etc/resolver/telepresence*
   ```

8. **Check resolver configuration:**

   ```sh
   cat /etc/resolver/telepresence.service-a-ns
   cat /etc/resolver/telepresence.cluster.local
   ```

### UDP Port Detection Commands

The following commands were used to detect the UDP port 51011:

```sh
sudo lsof -i UDP:56909 -P -n
```

`56909` is the PID of telepresence daemon foreground process.

### Key Discovery Notes

- The UDP port `51011` was only visible when checking the specific root daemon process with sudo privileges
- TUN interface `utun6` was identified by correlating routing table entries with Telepresence status subnets
- Multiple API connections were discovered through process-specific network connection analysis

## Kubernetes Resources

### Discovery Commands

The following kubectl commands were used to analyze the Telepresence Kubernetes resources:

#### 1. Ambassador Namespace Resources

**Command:**
```sh
kubectl -n ambassador get po,svc
```

**Output:**
```sh
NAME                                  READY   STATUS    RESTARTS   AGE
pod/traffic-manager-5cf65656b-gd9h2   1/1     Running   0          5h49m

NAME                      TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/agent-injector    ClusterIP   10.100.121.24   <none>        8443/TCP   5h49m
service/traffic-manager   ClusterIP   None            <none>        8081/TCP   5h49m
```

#### 2. Application Namespace Resources

**Command:**
```sh
kubectl -n service-a-ns get po,svc
```

**Output:**
```sh
NAME                                       READY   STATUS    RESTARTS   AGE
pod/service-a-deployment-87467f56b-qftd6   2/2     Running   0          27m

NAME                TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/service-a   ClusterIP   10.100.225.66   <none>        8080/TCP   5h53m
```

#### 3. Container Details for Intercepted Pod

**Command:**
```sh
kubectl get pod service-a-deployment-87467f56b-qftd6 -n service-a-ns -o json | jq -r '
  .spec.containers as $containers |
  .status.containerStatuses as $statuses |
  "POD\tNAMESPACE\tCONTAINER\tIMAGE\tREADY",
  range(0; $containers | length) as $i |
  "\(.metadata.name)\t\(.metadata.namespace)\t\($containers[$i].name)\t\($containers[$i].image)\t\($statuses[$i].ready // "unknown")"
' | column -t
```

**Output:**
```sh
POD                                   NAMESPACE     CONTAINER      IMAGE                               READY
service-a-deployment-87467f56b-qftd6  service-a-ns  server         node:alpine                         true
service-a-deployment-87467f56b-qftd6  service-a-ns  traffic-agent  ghcr.io/telepresenceio/tel2:2.24.0  true
```

### Telepresence Infrastructure Components

#### Ambassador Namespace (Traffic Manager)

**Components:**
- **traffic-manager pod**: Central coordinator for all Telepresence operations in the cluster
- **agent-injector service**: Webhook service that automatically injects traffic agents into intercepted pods
- **traffic-manager service**: Headless service for traffic manager communication (port 8081)

#### Application Namespace (service-a-ns)

**Components:**
- **service-a-deployment pod**: Application pod with 2/2 containers ready (original app + traffic agent)
- **service-a service**: ClusterIP service exposing the application on port 8080

#### Container Analysis

- **server container**: Original application container running Node.js on Alpine Linux
- **traffic-agent container**: Telepresence sidecar container that handles traffic interception and routing
- Both containers are ready and running, indicating successful traffic agent injection

### Traffic Agent Injection Process

When Telepresence prepares a deployment for interception:

1. **Agent Injection**: The agent-injector webhook automatically adds the traffic-agent sidecar container
2. **Network Sharing**: Both containers share the same network namespace (pod network)
3. **Traffic Routing**: The traffic-agent intercepts incoming traffic and can route it to local development environment
4. **Transparent Operation**: The original application container continues running normally

### Resource Relationships

```sh
Traffic Manager (ambassador namespace)
├── Coordinates all intercept operations
├── Communicates with traffic agents via port 8081
└── Manages cluster-wide Telepresence state

Traffic Agent (service-a-ns)
├── Injected as sidecar container in target pod
├── Shares network namespace with application container
├── Routes traffic between cluster and local development
└── Reports status back to traffic manager
```

## Summary

This Telepresence setup provides seamless local development against a private EKS cluster through:

1. **Secure Access**: AWS SSM port forwarding eliminates need for VPN or bastion host access
2. **Network Transparency**: TUN interface routes cluster traffic seamlessly
3. **DNS Integration**: Local DNS server resolves Kubernetes service names automatically
4. **Sidecar Injection**: Automatic traffic agent deployment for seamless traffic interception

The architecture enables developers to work locally while maintaining full connectivity to remote cluster services, with transparent service discovery and network routing.
