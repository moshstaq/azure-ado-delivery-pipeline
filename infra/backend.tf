terraform {
  backend "azurerm" {

    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstate7tcl"
    container_name       = "tfstate-ado"
    key                  = "ado-pipeline-aca.tfstate"
  }

}
