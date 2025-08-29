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

#### Usage

* Intercept a service port - `telepresence intercept service-a-deployment --port 8080:8080`
  * Now we can run the local "service-a" application - `node local.js` and see the calls to the service being routed to our local machine. We can test it by running `curl service-a.service-a-ns:8080`.
  * This also demonstrates that our code running locally can call `service-b` which is running in the cluster.
* Stop proxying - `telepresence leave service-a-deployment`
* Stop local Telepresence Daemons - `telepresence quit -s`

### Peeking under the hood

Refer to [Connectivity Analysis](./connectivity-analysis.md)

### Using Telepresence with Kyverno

Refer to [Telepresence and Kyverno](./telepresence-with-kyverno.md)