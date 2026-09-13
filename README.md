# AWS Kubernetes Cluster Autoscaler 

This repository creates a self-managed Kubernetes cluster on AWS using:

* Terraform — AWS infrastructure
* Ansible — Kubernetes configuration
* kubeadm — Kubernetes cluster initialization
* containerd — Container runtime
* Flannel — Pod networking
* AWS Cloud Controller Manager (AWS CCM)
* Kubernetes Cluster Autoscaler
* AWS EC2 Auto Scaling Group
* AWS Systems Manager Parameter Store — worker join command

The platform is designed to create a Kubernetes cluster in a **new AWS account, new AWS region, and new VPC**.

---

# 1. Prerequisites

Install and configure:

* AWS CLI
* Terraform
* Ansible
* kubectl
* Git
* Python 3

For Terraform execution on Windows, use **Ubuntu WSL** rather than running Terraform from `/mnt/c`.

Check the tools:

```bash
aws --version
terraform version
ansible --version
kubectl version --client
git --version
python3 --version
```

---

# 2. Configure AWS CLI

Configure the AWS account that will host the Kubernetes cluster:

```bash
aws configure
```

Enter:

```text
AWS Access Key ID:
AWS Secret Access Key:
Default region name:
Default output format:
```

For example:

```text
Default region name: us-east-1
Default output format: json
```

Verify the AWS account:

```bash
aws sts get-caller-identity
```

Verify the selected region:

```bash
aws configure get region
```

---

# 3. Clone the Repository

```bash
git clone <YOUR_GITHUB_REPOSITORY_URL>
cd aws-k8s-platform
```

---

# 4. Configure Terraform

Go to the Terraform environment:

```bash
cd terraform/environments/default
```

Create the Terraform variables file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit the variables:

```bash
nano terraform.tfvars
```

For Windows/WSL, you can also use:

```bash
code terraform.tfvars
```

Example:

```hcl
project_name = "aws-k8s-platform"

cluster_name = "k8s-cluster"

aws_region = "us-east-1"

network_mode = "managed"

pod_cidr = "10.244.0.0/16"

service_cidr = "10.96.0.0/12"

ami_id = "<UBUNTU_AMI_ID>"

control_plane_instance_type = "t3.medium"

worker_instance_type = "t3.small"

key_name = "<AWS_KEY_PAIR_NAME>"

worker_min_size = 1

worker_desired_size = 1

worker_max_size = 5

kubernetes_version = "1.30.14"

kubernetes_minor_version = "1.30"

ssm_join_parameter = "/k8s/join-command"

root_volume_size = 30

root_volume_type = "gp3"

admin_cidr = "<YOUR_ADMIN_PUBLIC_IP>/32"

enable_ssh = true

enable_public_api = true

enable_nodeport = false

enable_http_https = false
```

> Do not commit `terraform.tfvars`. It is ignored by `.gitignore`.

---

# 5. Initialize Terraform

From:

```text
terraform/environments/default
```

run:

```bash
terraform init
```

---

# 6. Format Terraform

```bash
terraform fmt -recursive
```

Check formatting:

```bash
terraform fmt -check -recursive
```

---

# 7. Validate Terraform

```bash
terraform validate
```

Expected:

```text
Success! The configuration is valid.
```

---

# 8. Review Terraform Plan

Before creating AWS resources:

```bash
terraform plan
```

Review the resources carefully.

Terraform should create resources such as:

```text
VPC
Internet Gateway
Subnets
Route Tables
Security Groups
IAM Roles
IAM Instance Profiles
Control Plane EC2
Worker Launch Template
Worker Auto Scaling Group
```

---

# 9. Create AWS Infrastructure

If the Terraform plan is correct:

```bash
terraform apply
```

Terraform will ask for confirmation:

```text
Do you want to perform these actions?
```

Enter:

```text
yes
```

Terraform will then create the AWS infrastructure.

---

# 10. Check Terraform Outputs

After Terraform finishes:

```bash
terraform output
```

For machine-readable output:

```bash
terraform output -json
```

Important outputs include:

```text
VPC ID
Control Plane Private IP
Control Plane Public IP
Control Plane Instance ID
Worker ASG Name
Worker Security Group
Control Plane Security Group
```

---

# 11. Configure Ansible

Go back to the Ansible directory:

```bash
cd ../../..
cd ansible
```

Verify the directory:

```bash
pwd
```

Expected:

```text
.../aws-k8s-platform/ansible
```

---

# 12. Configure AWS Region and Cluster Name

Set the environment variables:

```bash
export AWS_REGION="us-east-1"
export K8S_CLUSTER_NAME="k8s-cluster"
```

Verify:

```bash
echo "$AWS_REGION"
echo "$K8S_CLUSTER_NAME"
```

---

# 13. Test Ansible Dynamic Inventory

Run:

```bash
ansible-inventory --graph
```

The inventory should discover the AWS instances automatically using their Kubernetes cluster and role tags.

You should see groups similar to:

```text
@all:
  |--@control_plane:
  |  |--<control-plane-private-ip>
  |--@workers:
  |  |--<worker-private-ip>
```

---

# 14. Verify SSH Connectivity

Test all discovered instances:

```bash
ansible all -m ping
```

Expected:

```text
SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

If SSH uses a specific private key, configure it in the Ansible inventory or SSH configuration.

---

# 15. Prepare Kubernetes Nodes

Run:

```bash
ansible-playbook playbooks/prepare-nodes.yml
```

This prepares the EC2 instances by configuring:

* Hostname
* Swap
* Kernel modules
* Sysctl parameters
* Required OS packages
* Basic system configuration

---

# 16. Configure Containerd

Run:

```bash
ansible-playbook playbooks/containerd.yml
```

Verify containerd:

```bash
ansible kubernetes -a "systemctl is-active containerd"
```

Expected:

```text
active
```

---

# 17. Install Kubernetes Packages

Run:

```bash
ansible-playbook playbooks/kubernetes.yml
```

This installs:

```text
kubelet
kubeadm
kubectl
```

The Kubernetes packages are held at the configured version.

Verify:

```bash
ansible kubernetes -a "kubeadm version"
```

---

# 18. Initialize the Control Plane

Run:

```bash
ansible-playbook playbooks/control-plane.yml
```

This performs:

1. `kubeadm init`
2. Configures the Kubernetes administrator kubeconfig
3. Configures the control-plane kubelet
4. Waits for the API server
5. Generates the worker join command
6. Stores the join command in AWS SSM Parameter Store

Verify the SSM parameter:

```bash
aws ssm get-parameter \
  --name "/k8s/join-command" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text
```

---

# 19. Configure Worker Nodes

Run:

```bash
ansible-playbook playbooks/workers.yml
```

Workers retrieve the Kubernetes join command from AWS SSM Parameter Store and execute:

```text
kubeadm join
```

After the workers join the cluster, verify them from the control plane.

---

# 20. Configure kubectl

SSH into the control-plane server:

```bash
ssh ubuntu@<CONTROL_PLANE_PUBLIC_IP>
```

Configure kubectl:

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
```

Verify:

```bash
kubectl get nodes -o wide
```

At this stage the nodes may still show:

```text
NotReady
```

because the CNI has not been installed yet.

---

# 21. Install Flannel

Run from the Ansible directory:

```bash
ansible-playbook playbooks/flannel.yml
```

Wait for the nodes:

```bash
kubectl get nodes -o wide
```

Expected:

```text
NAME                  STATUS   ROLES           AGE   VERSION
<control-plane>       Ready    control-plane   ...   v1.30.14
<worker>              Ready    <none>          ...   v1.30.14
```

Check Flannel:

```bash
kubectl get pods -n kube-flannel
```

---

# 22. Install AWS Cloud Controller Manager

Run:

```bash
ansible-playbook playbooks/aws-ccm.yml
```

Verify:

```bash
kubectl get pods -n kube-system | grep cloud-controller
```

Check the deployment:

```bash
kubectl get deployment -n kube-system
```

The AWS Cloud Controller Manager should be running successfully.

---

# 23. Install Cluster Autoscaler

Run:

```bash
ansible-playbook playbooks/cluster-autoscaler.yml
```

Verify:

```bash
kubectl get deployment cluster-autoscaler -n kube-system
```

Check the pod:

```bash
kubectl get pods -n kube-system | grep cluster-autoscaler
```

Check logs:

```bash
kubectl logs -n kube-system deployment/cluster-autoscaler
```

---

# 24. Verify the Complete Cluster

Run:

```bash
kubectl get nodes -o wide
```

```bash
kubectl get pods -A
```

```bash
kubectl get deployments -A
```

```bash
kubectl get daemonsets -A
```

```bash
kubectl get svc -A
```

Check Kubernetes component health:

```bash
kubectl get --raw='/readyz?verbose'
```

---

# 25. Verify AWS Cloud Controller Manager

Check the CCM pod:

```bash
kubectl get pods -n kube-system | grep cloud-controller
```

Check logs:

```bash
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-cloud-controller-manager \
  --tail=100
```

---

# 26. Verify Cluster Autoscaler

Check the deployment:

```bash
kubectl get deployment cluster-autoscaler -n kube-system
```

Check the pod:

```bash
kubectl get pods -n kube-system \
  -l app.kubernetes.io/name=cluster-autoscaler
```

Check logs:

```bash
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=cluster-autoscaler \
  --tail=200
```

You should see the Auto Scaling Group being discovered.

---

# 27. Test Cluster Autoscaler Scale-Up

Create a test deployment:

```bash
kubectl create deployment autoscaler-test \
  --image=nginx \
  --replicas=1
```

Scale it beyond the current worker capacity:

```bash
kubectl scale deployment autoscaler-test --replicas=10
```

Check pods:

```bash
kubectl get pods -o wide
```

Some pods should become:

```text
Pending
```

Check Cluster Autoscaler:

```bash
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=cluster-autoscaler \
  --tail=200
```

Check AWS ASG:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names k8s-cluster-worker-asg \
  --query 'AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize}'
```

A new EC2 worker should be launched.

The worker bootstrap script then:

1. Installs/configures the required components
2. Retrieves the join command from SSM
3. Connects to the control-plane API
4. Executes `kubeadm join`
5. Starts kubelet
6. Becomes a Kubernetes worker

Check:

```bash
kubectl get nodes -o wide
```

---

# 28. Test Cluster Autoscaler Scale-Down

After testing:

```bash
kubectl delete deployment autoscaler-test
```

Check:

```bash
kubectl get nodes -o wide
```

Check Cluster Autoscaler logs:

```bash
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=cluster-autoscaler \
  --tail=200
```

The Auto Scaling Group should eventually reduce the worker count toward the configured minimum.

---

# 29. Final Validation

Run:

```bash
kubectl get nodes
```

```bash
kubectl get pods -A
```

```bash
kubectl get deployment -A
```

```bash
kubectl get svc -A
```

```bash
kubectl get events -A --sort-by=.lastTimestamp
```

Check the AWS worker ASG:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names k8s-cluster-worker-asg
```

Check EC2 instances:

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:kubernetes.io/cluster/k8s-cluster,Values=owned" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ID:InstanceId,PrivateIP:PrivateIpAddress,State:State.Name,Type:InstanceType}' \
  --output table
```

---

# 30. Destroy the Infrastructure

**Warning:** This permanently deletes the Terraform-managed AWS infrastructure.

From:

```text
terraform/environments/default
```

run:

```bash
terraform destroy
```

Confirm:

```text
yes
```

After destruction, verify:

```bash
terraform state list
```

The Terraform-managed resources should no longer exist.

---

# Deployment Flow

The complete deployment flow is:

```text
AWS CLI
   |
   v
Terraform
   |
   +--> VPC
   +--> Subnets
   +--> Internet Gateway
   +--> Route Tables
   +--> Security Groups
   +--> IAM Roles
   +--> Control Plane EC2
   +--> Worker Launch Template
   +--> Worker Auto Scaling Group
   |
   v
Ansible
   |
   +--> Prepare EC2 Nodes
   +--> Install containerd
   +--> Install Kubernetes
   +--> kubeadm init
   +--> kubeadm join
   |
   v
Kubernetes Cluster
   |
   +--> Flannel
   +--> AWS CCM
   +--> Cluster Autoscaler
   |
   v
Running Kubernetes Platform
```

## Worker Auto Scaling Flow

When Kubernetes needs additional capacity:

```text
Pending Pods
     |
     v
Cluster Autoscaler
     |
     v
AWS Auto Scaling Group
     |
     v
New EC2 Worker
     |
     v
Worker Bootstrap
     |
     v
Get Join Command from SSM
     |
     v
kubeadm join
     |
     v
Worker becomes Ready
     |
     v
Pending Pods are scheduled
```

This means that when the Cluster Autoscaler launches a new EC2 instance, the instance automatically configures itself and joins the Kubernetes cluster.
