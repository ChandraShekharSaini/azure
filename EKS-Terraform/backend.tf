terraform {
  backend "azurerm" {
    resource_group_name  = "1-01694db9-playground-sandbox"
    storage_account_name = "chandrastorage56"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
    use_azuread_auth = true
  }
}
