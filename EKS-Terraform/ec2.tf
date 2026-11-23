
###########################################################
# UBUNTU 24.04 IMAGE
###########################################################

data "azurerm_platform_image" "ubuntu_2404" {
  location  = azurerm_resource_group.eks_rg.location
  publisher = "Canonical"
  offer     = "ubuntu-24_04-lts"
  sku       = "server"
  version   = "latest"
}

###########################################################
# ADMIN VM USER ASSIGNED MANAGED IDENTITY
###########################################################

resource "azurerm_user_assigned_identity" "eks_admin" {
  name                = "aks-admin-managed-identity"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  tags = {
    Name        = "aks-admin-identity"
    Environment = "dev"
    Project     = "aks-project"
  }
}

###########################################################
# AKS CLUSTER USER ROLE
###########################################################

resource "azurerm_role_assignment" "admin_user" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"

  principal_id   = azurerm_user_assigned_identity.eks_admin.principal_id
  principal_type = "ServicePrincipal"
}

###########################################################
# AKS CLUSTER ADMIN ROLE
###########################################################

resource "azurerm_role_assignment" "admin_cluster" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"

  principal_id   = azurerm_user_assigned_identity.eks_admin.principal_id
  principal_type = "ServicePrincipal"
}

###########################################################
# ADMIN VM PUBLIC IP
###########################################################

resource "azurerm_public_ip" "eks_admin_ip" {
  name                = "aks-admin-public-ip"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  allocation_method = "Static"
  sku               = "Standard"

  tags = {
    Name = "aks-admin-public-ip"
  }
}

###########################################################
# ADMIN VM NETWORK INTERFACE
###########################################################

resource "azurerm_network_interface" "eks_admin_nic" {
  name                = "aks-admin-nic"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public1.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.eks_admin_ip.id
  }
}

###########################################################
# UBUNTU ADMIN VM
###########################################################

resource "azurerm_linux_virtual_machine" "eks_admin" {

  name                = "aks-admin-ubuntu"
  computer_name       = "aks-admin"
  resource_group_name = azurerm_resource_group.eks_rg.name
  location            = azurerm_resource_group.eks_rg.location

  size = "Standard_D2s_v3"

  admin_username = var.admin_username

  network_interface_ids = [
    azurerm_network_interface.eks_admin_nic.id
  ]

  disable_password_authentication = true

  #########################################################
  # SSH KEY
  #########################################################

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.admin_ssh_public_key))
  }

  #########################################################
  # UBUNTU IMAGE
  #########################################################

  source_image_id = data.azurerm_platform_image.ubuntu_2404.id

  #########################################################
  # OS DISK
  #########################################################

  os_disk {
    name                 = "aks-admin-os-disk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 50
  }

  #########################################################
  # MANAGED IDENTITY
  #########################################################

  identity {
    type = "UserAssigned"

    identity_ids = [
      azurerm_user_assigned_identity.eks_admin.id
    ]
  }

  #########################################################
  # USER DATA / CLOUD INIT
  #########################################################

  custom_data = base64encode(<<-EOF
#!/bin/bash

set -euxo pipefail

exec > /var/log/aks-admin-setup.log 2>&1

echo "Starting AKS Admin VM setup"

# Update packages
apt-get update -y

apt-get install -y \
  curl \
  unzip \
  tar \
  gzip \
  jq \
  ca-certificates \
  apt-transport-https \
  gnupg \
  lsb-release

###########################################################
# INSTALL AZURE CLI
###########################################################

curl -sL https://aka.ms/InstallAzureCLIDeb | bash

az version

###########################################################
# INSTALL KUBECTL AND KUBELOGIN
###########################################################

az aks install-cli \
  --install-location /usr/local/bin/kubectl \
  --kubelogin-install-location /usr/local/bin/kubelogin

kubectl version --client

kubelogin --version

###########################################################
# INSTALL HELM
###########################################################

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version

###########################################################
# CONFIGURE AZURE REGION
###########################################################

export ARM_LOCATION="${azurerm_resource_group.eks_rg.location}"

###########################################################
# MANAGED IDENTITY DETAILS
###########################################################

UAMI_CLIENT_ID="${azurerm_user_assigned_identity.eks_admin.client_id}"

###########################################################
# LOGIN USING MANAGED IDENTITY
###########################################################

until az login \
  --identity \
  --client-id "$UAMI_CLIENT_ID" \
  --output none
do
  sleep 20
done

###########################################################
# WAIT FOR AKS CLUSTER
###########################################################

while true; do

  STATUS=$(az aks show \
    --resource-group "${azurerm_resource_group.eks_rg.name}" \
    --name "${azurerm_kubernetes_cluster.aks.name}" \
    --query provisioningState \
    --output tsv 2>/dev/null || echo "NotFound")

  echo "AKS Status: $STATUS"

  if [ "$STATUS" = "Succeeded" ]; then
    break
  fi

  sleep 20

done

###########################################################
# CONFIGURE KUBECONFIG
###########################################################

mkdir -p /root/.kube

az aks get-credentials \
  --resource-group "${azurerm_resource_group.eks_rg.name}" \
  --name "${azurerm_kubernetes_cluster.aks.name}" \
  --overwrite-existing \
  --file /root/.kube/config

export KUBECONFIG=/root/.kube/config

###########################################################
# CONFIGURE MANAGED IDENTITY AUTHENTICATION
###########################################################

kubelogin convert-kubeconfig \
  -l msi \
  --client-id "$UAMI_CLIENT_ID"

###########################################################
# WAIT FOR KUBERNETES NODES
###########################################################

until kubectl get nodes >/dev/null 2>&1; do
  echo "Waiting for AKS nodes..."
  sleep 15
done

###########################################################
# DISPLAY CLUSTER INFORMATION
###########################################################

kubectl get nodes -o wide

kubectl get pods -A

kubectl get namespaces

echo "AKS Admin Ubuntu setup completed"

EOF
  )

  depends_on = [
    azurerm_role_assignment.admin_user,
    azurerm_role_assignment.admin_cluster
  ]

  tags = {
    Name        = "aks-admin"
    Environment = "dev"
    Project     = "aks-project"
  }
}

###########################################################
# OUTPUTS
###########################################################

output "aks_admin_public_ip" {
  value = azurerm_public_ip.eks_admin_ip.ip_address
}

output "aks_admin_private_ip" {
  value = azurerm_network_interface.eks_admin_nic.private_ip_address
}

output "aks_admin_identity_client_id" {
  value = azurerm_user_assigned_identity.eks_admin.client_id
}
