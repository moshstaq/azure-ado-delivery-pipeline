output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "container_app_url" {
  value = azurerm_container_app.this.latest_revision_fqdn
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "container_app_environment_id" {
  value = azurerm_container_app_environment.this.id
}
