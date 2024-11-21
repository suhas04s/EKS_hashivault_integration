#!/bin/bash

# Exit script on any error
set -e

# Variables
CLUSTER_NAME="learn-vault"
NODES=3
SSH_KEY_NAME="learn-vault"
EBS_ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"
EBS_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
ROOT_PASSWORD="root_password" # Replace with your MySQL root password

# Step 1: Create EKS Cluster
echo "Creating EKS Cluster..."
eksctl create cluster --name $CLUSTER_NAME --nodes $NODES --with-oidc --ssh-access --ssh-public-key $SSH_KEY_NAME --managed

# Step 2: Enable EBS CSI Driver
echo "Creating IAM role for EBS CSI driver..."
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster $CLUSTER_NAME \
  --attach-policy-arn $EBS_POLICY_ARN \
  --approve \
  --role-only \
  --role-name $EBS_ROLE_NAME

ROLE_ARN=$(aws iam get-role --role-name $EBS_ROLE_NAME --query "Role.Arn" --output text)

echo "Enabling EBS CSI driver..."
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME \
  --service-account-role-arn $ROLE_ARN

# Step 3: Install MySQL using Helm
echo "Adding Bitnami Helm repository..."
helm repo add bitnami https://charts.bitnami.com/bitnami

echo "Installing MySQL Helm chart..."
helm install mysql bitnami/mysql --set auth.rootPassword=$ROOT_PASSWORD

# Step 4: Install Vault using Helm
echo "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com

echo "Installing Vault Helm chart..."
helm install vault hashicorp/vault --set "server.ha.enabled=true"

# Step 5: Initialize and Unseal Vault
echo "Initializing Vault..."
kubectl exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > cluster-keys.json

UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" cluster-keys.json)

echo "Unsealing Vault..."
kubectl exec vault-0 -- vault operator unseal $UNSEAL_KEY

echo "Checking Vault status..."
kubectl exec vault-0 -- vault status

# Step 6: Join Additional Vault Pods to the Cluster
echo "Joining other Vault nodes to the cluster..."
for NODE in vault-1 vault-2; do
  kubectl exec $NODE -- vault operator raft join http://vault-0.vault-internal:8200
  kubectl exec $NODE -- vault operator unseal $UNSEAL_KEY
done

echo "Listing Vault cluster nodes..."
kubectl exec vault-0 -- vault operator raft list-peers

# Step 7: Enable and Configure Database Secrets in Vault
echo "Enabling database secrets engine..."
kubectl exec vault-0 -- vault secrets enable database

echo "Configuring MySQL in Vault..."
kubectl exec vault-0 -- vault write database/config/mysql \
  plugin_name=mysql-database-plugin \
  connection_url="{{username}}:{{password}}@tcp(mysql.default.svc.cluster.local:3306)/" \
  allowed_roles="readonly" \
  username="root" \
  password="$ROOT_PASSWORD"

echo "Creating a database role in Vault..."
kubectl exec vault-0 -- vault write database/roles/readonly \
  db_name=mysql \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';" \
  default_ttl="1h" \
  max_ttl="24h"

echo "Reading database credentials..."
kubectl exec vault-0 -- vault read database/creds/readonly

# Step 8: Configure Kubernetes Authentication
echo "Configuring Kubernetes authentication in Vault..."
kubectl exec vault-0 -- vault auth enable kubernetes
kubectl exec vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"

echo "Writing policy for Kubernetes authentication..."
kubectl exec vault-0 -- vault policy write devwebapp - <<EOF
path "database/creds/readonly" {
  capabilities = ["read"]
}
EOF

echo "Creating Kubernetes role for Vault..."
kubectl exec vault-0 -- vault write auth/kubernetes/role/devweb-app \
  bound_service_account_names=internal-app \
  bound_service_account_namespaces=default \
  policies=devwebapp \
  ttl=24h

# Step 9: Deploy Application
echo "Creating internal-app service account..."
kubectl apply --filename internal-app.yaml

echo "Deploying application..."
kubectl apply --filename devwebapp.yaml

echo "Displaying secrets from devwebapp..."
kubectl exec --stdin=true --tty=true devwebapp --container devwebapp -- cat /vault/secrets/database-connect.sh

echo "Setup complete!"
