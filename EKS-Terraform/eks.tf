
###########################################################
# TERRAFORM AND AZURE PROVIDER
###########################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

###########################################################
# VARIABLES
###########################################################

variable "location" {
  default = "East US"
}

variable "cluster_version" {
  description = "AKS Kubernetes version. Leave empty to use Azure default."
  type        = string
  default     = null
}

variable "admin_username" {
  default = "azureadmin"
}

variable "admin_ssh_public_key" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "admin_ssh_source_cidr" {
  description = "Your public IP CIDR for SSH access"
  type        = string
}

###########################################################
# RESOURCE GROUP
###########################################################

resource "azurerm_resource_group" "eks_rg" {
  name     = "chandra-aks-rg"
  location = var.location

  tags = {
    Environment = "dev"
    Project     = "aks-project"
    Owner       = "chandraops"
  }
}

###########################################################
# VIRTUAL NETWORK
###########################################################

resource "azurerm_virtual_network" "eks_vnet" {
  name                = "aks-vnet"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    Name = "aks-vnet"
  }
}

###########################################################
# PUBLIC SUBNET 1
###########################################################

resource "azurerm_subnet" "public1" {
  name                 = "aks-public-1"
  resource_group_name  = azurerm_resource_group.eks_rg.name
  virtual_network_name = azurerm_virtual_network.eks_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

###########################################################
# PUBLIC SUBNET 2
###########################################################

resource "azurerm_subnet" "public2" {
  name                 = "aks-public-2"
  resource_group_name  = azurerm_resource_group.eks_rg.name
  virtual_network_name = azurerm_virtual_network.eks_vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

###########################################################
# PRIVATE SUBNET 1
###########################################################

resource "azurerm_subnet" "private1" {
  name                 = "aks-private-1"
  resource_group_name  = azurerm_resource_group.eks_rg.name
  virtual_network_name = azurerm_virtual_network.eks_vnet.name
  address_prefixes     = ["10.0.3.0/24"]
}

###########################################################
# PRIVATE SUBNET 2
###########################################################

resource "azurerm_subnet" "private2" {
  name                 = "aks-private-2"
  resource_group_name  = azurerm_resource_group.eks_rg.name
  virtual_network_name = azurerm_virtual_network.eks_vnet.name
  address_prefixes     = ["10.0.4.0/24"]
}

###########################################################
# NAT PUBLIC IP
###########################################################

resource "azurerm_public_ip" "nat_ip" {
  name                = "aks-nat-public-ip"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  allocation_method = "Static"
  sku               = "Standard"

  tags = {
    Name = "aks-nat-ip"
  }
}

###########################################################
# NAT GATEWAY
###########################################################

resource "azurerm_nat_gateway" "nat" {
  name                = "aks-nat-gateway"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
}

resource "azurerm_nat_gateway_public_ip_association" "nat_ip" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat_ip.id
}

###########################################################
# NAT GATEWAY SUBNET ASSOCIATIONS
###########################################################

resource "azurerm_subnet_nat_gateway_association" "private1" {
  subnet_id      = azurerm_subnet.private1.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "private2" {
  subnet_id      = azurerm_subnet.private2.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

###########################################################
# NETWORK SECURITY GROUP
###########################################################

resource "azurerm_network_security_group" "aks_nsg" {
  name                = "aks-nsg"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_ssh_source_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    Name = "aks-nsg"
  }
}

###########################################################
# NSG SUBNET ASSOCIATIONS
###########################################################

resource "azurerm_subnet_network_security_group_association" "private1" {
  subnet_id                 = azurerm_subnet.private1.id
  network_security_group_id = azurerm_network_security_group.aks_nsg.id
}

resource "azurerm_subnet_network_security_group_association" "private2" {
  subnet_id                 = azurerm_subnet.private2.id
  network_security_group_id = azurerm_network_security_group.aks_nsg.id
}

resource "azurerm_subnet_network_security_group_association" "public1" {
  subnet_id                 = azurerm_subnet.public1.id
  network_security_group_id = azurerm_network_security_group.aks_nsg.id
}

###########################################################
# AKS CLUSTER
###########################################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "chandra"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name
  dns_prefix          = "chandra-aks"

  kubernetes_version = var.cluster_version

  sku_tier = "Free"

  role_based_access_control_enabled = true
  local_account_disabled            = true

  #########################################################
  # SYSTEM NODE POOL
  #########################################################

  default_node_pool {
    name           = "systempool"
    vm_size        = "Standard_D2s_v3"
    vnet_subnet_id = azurerm_subnet.private1.id

    auto_scaling_enabled = true

    min_count = 1
    max_count = 6

    os_sku    = "Ubuntu"
    os_disk_size_gb = 50
    max_pods  = 30

    tags = {
      Environment = "dev"
      Project     = "aks-project"
    }
  }

  #########################################################
  # MANAGED IDENTITY
  #########################################################

  identity {
    type = "SystemAssigned"
  }

  #########################################################
  # NETWORK PROFILE
  #########################################################

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"

    outbound_type = "userAssignedNATGateway"

    service_cidr   = "10.2.0.0/16"
    dns_service_ip = "10.2.0.10"
    pod_cidr       = "10.244.0.0/16"

    load_balancer_sku = "standard"
  }

  #########################################################
  # WORKLOAD IDENTITY
  #########################################################

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  #########################################################
  # AZURE RBAC
  #########################################################

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
  }

  tags = {
    Name        = "chandra"
    Environment = "dev"
    Project     = "aks-project"
  }

  depends_on = [
    azurerm_subnet_nat_gateway_association.private1,
    azurerm_subnet_nat_gateway_association.private2,
    azurerm_subnet_network_security_group_association.private1,
    azurerm_subnet_network_security_group_association.private2
  ]
}

###########################################################
# AKS NETWORK CONTRIBUTOR PERMISSION
###########################################################

resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_subnet.private1.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

resource "azurerm_role_assignment" "aks_network2" {
  scope                = azurerm_subnet.private2.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

###########################################################
# ADDITIONAL AKS NODE POOL
###########################################################

resource "azurerm_kubernetes_cluster_node_pool" "worker" {
  name                  = "workerpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id

  vm_size        = "Standard_D2s_v3"
  vnet_subnet_id = azurerm_subnet.private2.id

  auto_scaling_enabled = true

  min_count = 1
  max_count = 6

  os_type = "Linux"
  os_sku  = "Ubuntu"

  os_disk_size_gb = 50
  max_pods         = 30

  node_labels = {
    role        = "worker"
    environment = "dev"
  }

  tags = {
    Name        = "aks-worker"
    Environment = "dev"
    Project     = "aks-project"
    Owner       = "chandraops"
  }

  depends_on = [
    azurerm_role_assignment.aks_network2
  ]
}

###########################################################
# ADMIN VM PUBLIC IP
###########################################################

resource "azurerm_public_ip" "admin_ip" {
  name                = "aks-admin-public-ip"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  allocation_method = "Static"
  sku               = "Standard"
}

###########################################################
# ADMIN VM NETWORK INTERFACE
###########################################################

resource "azurerm_network_interface" "admin_nic" {
  name                = "aks-admin-nic"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public1.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.admin_ip.id
  }
}

###########################################################
# ADMIN VM
###########################################################

resource "azurerm_linux_virtual_machine" "admin" {
  name                = "aks-admin-vm"
  resource_group_name = azurerm_resource_group.eks_rg.name
  location            = azurerm_resource_group.eks_rg.location

  size = "Standard_B2s"

  admin_username = var.admin_username

  network_interface_ids = [
    azurerm_network_interface.admin_nic.id
  ]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.admin_ssh_public_key))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  #########################################################
  # SYSTEM ASSIGNED IDENTITY
  #########################################################

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(<<-EOF
#!/bin/bash
set -eux

apt-get update
apt-get install -y ca-certificates curl apt-transport-https gnupg lsb-release

# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Install kubectl
az aks install-cli
EOF
  )

  tags = {
    Name = "aks-admin-vm"
  }
}

###########################################################
# ADMIN VM AKS USER ACCESS
###########################################################

resource "azurerm_role_assignment" "admin_user" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_linux_virtual_machine.admin.identity[0].principal_id
}

###########################################################
# ADMIN VM AKS CLUSTER ADMIN ACCESS
###########################################################

resource "azurerm_role_assignment" "admin_cluster" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azurerm_linux_virtual_machine.admin.identity[0].principal_id
}

###########################################################
# OUTPUTS
###########################################################

output "resource_group" {
  value = azurerm_resource_group.eks_rg.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "aks_cluster_id" {
  value = azurerm_kubernetes_cluster.aks.id
}

output "aks_node_resource_group" {
  value = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "aks_oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

output "admin_vm_public_ip" {
  value = azurerm_public_ip.admin_ip.ip_address
}

output "nat_public_ip" {
  value = azurerm_public_ip.nat_ip.ip_address
}
