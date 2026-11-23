###########################################################
# MYSQL DELEGATED SUBNET
###########################################################

resource "azurerm_subnet" "mysql_subnet" {
  name                 = "mysql-private-subnet"
  resource_group_name  = azurerm_resource_group.eks_rg.name
  virtual_network_name = azurerm_virtual_network.eks_vnet.name

  address_prefixes = ["10.0.5.0/24"]

  delegation {
    name = "mysql-delegation"

    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"

      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

###########################################################
# MYSQL PRIVATE DNS ZONE
###########################################################

resource "azurerm_private_dns_zone" "mysql_dns" {
  name = "shopping-mysql.mysql.database.azure.com"

  resource_group_name = azurerm_resource_group.eks_rg.name

  tags = {
    Name = "shopping-mysql-dns"
  }
}

###########################################################
# MYSQL PRIVATE DNS VNET LINK
###########################################################

resource "azurerm_private_dns_zone_virtual_network_link" "mysql_dns_link" {
  name = "shopping-mysql-vnet-link"

  resource_group_name = azurerm_resource_group.eks_rg.name

  private_dns_zone_name = azurerm_private_dns_zone.mysql_dns.name

  virtual_network_id = azurerm_virtual_network.eks_vnet.id

  registration_enabled = false
}

###########################################################
# MYSQL NETWORK SECURITY GROUP
###########################################################

resource "azurerm_network_security_group" "mysql_sg" {
  name                = "mysql-private-nsg"
  location            = azurerm_resource_group.eks_rg.location
  resource_group_name = azurerm_resource_group.eks_rg.name

  security_rule {
    name                       = "AllowMySQLFromAKS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"

    source_port_range      = "*"
    destination_port_range = "3306"

    source_address_prefix = "10.0.3.0/24"

    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"

    source_port_range      = "*"
    destination_port_range = "*"

    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    Name = "mysql-private-nsg"
  }
}

###########################################################
# MYSQL SUBNET NSG ASSOCIATION
###########################################################

resource "azurerm_subnet_network_security_group_association" "mysql" {
  subnet_id = azurerm_subnet.mysql_subnet.id

  network_security_group_id = azurerm_network_security_group.mysql_sg.id
}

###########################################################
# MYSQL FLEXIBLE SERVER
###########################################################

resource "azurerm_mysql_flexible_server" "mysql" {

  name = "shopping-mysql-chandra"

  resource_group_name = azurerm_resource_group.eks_rg.name

  location = azurerm_resource_group.eks_rg.location

  administrator_login    = "admin"
  administrator_password = var.mysql_password

  version = "8.0.21"

  sku_name = "B_Standard_B1ms"

  delegated_subnet_id = azurerm_subnet.mysql_subnet.id

  private_dns_zone_id = azurerm_private_dns_zone.mysql_dns.id

  public_network_access = "Disabled"

  backup_retention_days = 7

  geo_redundant_backup_enabled = false

  zone = "1"

  storage {
    size_gb           = 20
    auto_grow_enabled = true
    iops              = 360
  }

  tags = {
    Name        = "shopping-mysql"
    Environment = "dev"
    Project     = "aks-project"
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.mysql_dns_link,
    azurerm_subnet_network_security_group_association.mysql
  ]
}

###########################################################
# MYSQL DATABASE
###########################################################

resource "azurerm_mysql_flexible_database" "cloud" {

  name                = "cloud"
  resource_group_name = azurerm_resource_group.eks_rg.name

  server_name = azurerm_mysql_flexible_server.mysql.name

  charset   = "utf8mb4"
  collation = "utf8mb4_unicode_ci"
}

###########################################################
# MYSQL OUTPUTS
###########################################################

output "mysql_server_name" {
  value = azurerm_mysql_flexible_server.mysql.name
}

output "mysql_fqdn" {
  value = azurerm_mysql_flexible_server.mysql.fqdn
}

output "mysql_database" {
  value = azurerm_mysql_flexible_database.cloud.name
}

output "mysql_port" {
  value = 3306 hard code valuer here
}
