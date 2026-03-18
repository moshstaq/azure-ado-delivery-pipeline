variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Resource group for all Project 2 resources"
  type        = string
  default     = "rg-project2"
}

variable "key_vault_name" {
  description = "Name of the Key Vault instance"
  type        = string
  default     = "kv-ado-project2"
}

variable "acr_name" {
  description = "Name of the Azure Container Registry"
  type        = string
  default     = "acrproject2"
}

variable "container_app_env_name" {
  description = "Name of the Container Apps environment"
  type        = string
  default     = "cae-project2"
}

variable "container_app_name" {
  description = "Name of the Container App"
  type        = string
  default     = "ca-fastapi"
}

variable "deployment_ip" {
  description = "Public IP of the deployment machine allowed through Key Vault network ACL"
  type        = string
}

variable "acr_login_server" {
  description = "ACR login server address"
  type        = string
  default     = "acrproject2.azurecr.io"
}
