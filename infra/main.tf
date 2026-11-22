data "azurerm_client_config" "current" {}

# --- Platform network: read-only, owned by the landing zone ---
data "azurerm_subnet" "aca" {
  name                 = "snet-containers"
  virtual_network_name = "vnet-workloads"
  resource_group_name  = "rg-workloads"
}

data "azurerm_subnet" "pe" {
  name                 = "snet-compute"
  virtual_network_name = "vnet-workloads"
  resource_group_name  = "rg-workloads"
}

data "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = "rg-platform-connectivity"
}

data "azurerm_log_analytics_workspace" "this" {
  name                = "law-platform"
  resource_group_name = "rg-platform-management"
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_key_vault" "this" {
  name                          = var.key_vault_name
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  soft_delete_retention_days    = 7
  purge_protection_enabled      = false
  rbac_authorization_enabled    = true
  public_network_access_enabled = true

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = [var.deployment_ip]
  }
}

resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "app_secret" {
  name         = "app-secret"
  key_vault_id = azurerm_key_vault.this.id
  value        = "placeholder-set-via-cli"
  lifecycle {
    ignore_changes = [value]
  }

  depends_on = [azurerm_role_assignment.kv_admin]

  tags = { "file-encoding" = "utf-8" }
}

resource "azurerm_container_registry" "this" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_container_app_environment" "this" {
  name                       = var.container_app_env_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id

  infrastructure_subnet_id = data.azurerm_subnet.aca.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
  timeouts {
    create = "60m"
  }
}

# --- Private endpoint: the app reaches the vault privately ---
resource "azurerm_private_endpoint" "kv" {
  name                = "pe-${var.key_vault_name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = data.azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-${var.key_vault_name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.kv.id]
  }
}

resource "azurerm_container_app" "this" {
  name                         = var.container_app_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"

  # Attach the identity: these use .id (the Azure resource)
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = var.acr_login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  secret {
    name                = "app-secret"
    key_vault_secret_id = azurerm_key_vault_secret.app_secret.versionless_id # always the latest version
    identity            = azurerm_user_assigned_identity.app.id
  }

  template {
    container {
      name   = "fastapi"
      image  = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "APP_ENV"
        value = var.app_env
      }
      env {
        name  = "APP_REGION"
        value = var.location
      }
      env {
        name        = "APP_SECRET"
        secret_name = "app-secret"
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  depends_on = [
    azurerm_role_assignment.aca_acr_pull,
    azurerm_role_assignment.aca_kv_secrets_user,
    azurerm_private_endpoint.kv
  ]
}
resource "azurerm_role_assignment" "aca_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_role_assignment" "aca_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}


resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.container_app_name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}
