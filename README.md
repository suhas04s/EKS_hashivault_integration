# EKS Cluster with HashiCorp Vault for Secrets Management and MySQL Integration

This repository contains automation scripts and instructions to set up an Amazon EKS (Elastic Kubernetes Service) cluster, install HashiCorp Vault and MySQL using Helm, and configure Vault for managing database secrets. The setup also demonstrates Kubernetes authentication with Vault and deployment of a sample application that retrieves database credentials securely.

## **Key Components**

### **1. Amazon EKS Cluster**
Amazon Elastic Kubernetes Service (EKS) is a managed Kubernetes service that simplifies deploying, managing, and scaling containerized applications using Kubernetes. 
- **Purpose in this setup**: EKS serves as the core infrastructure to deploy Vault, MySQL, and the sample application.

### **2. HashiCorp Vault**
Vault is a tool for securely storing and accessing secrets such as API keys, passwords, and certificates.
- **Purpose in this setup**: Vault manages database credentials dynamically and securely. It integrates with Kubernetes for pod-based authentication and authorization.

### **3. Amazon Elastic Block Store (EBS)**
EBS is a block storage service designed for use with EC2 instances.
- **Purpose in this setup**: The EBS CSI driver enables Kubernetes pods to use EBS volumes for persistent storage.

### **4. Helm**
Helm is a package manager for Kubernetes, simplifying the deployment of applications and services using pre-configured charts.
- **Purpose in this setup**: Used to deploy MySQL and Vault on the EKS cluster.

### **5. MySQL**
MySQL is a popular open-source relational database management system.
- **Purpose in this setup**: Serves as the backend database whose credentials are managed dynamically by Vault.

---

## **Setup Steps**

### **Prerequisites**
1. AWS CLI, `eksctl`, `kubectl`, and `helm` installed and configured.
2. An AWS account with the necessary IAM permissions.
3. SSH key pair for cluster access.

### **Steps**

Create an EKS Cluster:
   eksctl create cluster --name learn-vault --nodes 3 --with-oidc --ssh-access --ssh-public-key <your-ssh-key> --managed

Enable EBS CSI Driver:
eksctl create iamserviceaccount --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster learn-vault \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve --role-only --role-name AmazonEKS_EBS_CSI_DriverRole
  
eksctl create addon --name aws-ebs-csi-driver --cluster learn-vault \
  --service-account-role-arn arn:aws:iam::<your-account-id>:role/AmazonEKS_EBS_CSI_DriverRole

Deploy MySQL:
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install mysql bitnami/mysql --set auth.rootPassword=<your-root-password>

Deploy HashiCorp Vault:
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault --set "server.ha.enabled=true"

Initialize and Unseal Vault:
kubectl exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > cluster-keys.json
kubectl exec vault-0 -- vault operator unseal $(jq -r ".unseal_keys_b64[]" cluster-keys.json)

Configure Database Secrets in Vault:
kubectl exec vault-0 -- vault secrets enable database
kubectl exec vault-0 -- vault write database/config/mysql \
  plugin_name=mysql-database-plugin \
  connection_url="{{username}}:{{password}}@tcp(mysql.default.svc.cluster.local:3306)/" \
  allowed_roles="readonly" \
  username="root" \
  password=<your-root-password>

kubectl exec vault-0 -- vault write database/roles/readonly \
  db_name=mysql \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';" \
  default_ttl="1h" \
  max_ttl="24h"

Configure Kubernetes Authentication:
kubectl exec vault-0 -- vault auth enable kubernetes
kubectl exec vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"

Deploy Sample Application

Apply the Kubernetes manifests:
kubectl apply -f internal-app.yaml
kubectl apply -f devwebapp.yaml

Verify the secrets retrieved:
kubectl exec --stdin=true --tty=true devwebapp --container devwebapp -- cat /vault/secrets/database-connect.sh
