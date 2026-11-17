# azure-ado-delivery-pipeline

A CI/CD pipeline using Azure DevOps as the orchestration layer, GitHub as the source control platform, and Azure Container Apps as the deployment target.

## Overview

GitHub hosts the source code and Azure DevOps governs the delivery process, the split many organisations run when developer collaboration sits on one platform and release control sits on another. The two platforms are connected via a service connection, keeping developer collaboration separate from deployment orchestration.

The pipeline enforces a delivery process rather than just running automation. No image reaches the registry without passing a vulnerability gate, and no deployment occurs without explicit approval. The application reads its secret from a Key Vault that it reaches only over a private endpoint.

## Architecture

```
GitHub Repository
      │
      ├── GitHub Actions: security-scan (every PR touching app/, weekly schedule)
      ├── Dependabot (weekly PRs for pip packages and the base image)
      │
      │  trigger (pull request validation, push to main)
      ▼
Azure DevOps Pipeline (self-hosted agent)
      │
      ├── Stage 1: Build and Scan
      │     ├── Docker build
      │     ├── Trivy report scan (all CRITICAL/HIGH, never fails)
      │     ├── Trivy gate (fails on fixable CRITICAL/HIGH)
      │     └── Image saved as pipeline artifact
      │
      ├── Stage 2: Push to ACR
      │     ├── Image loaded from artifact (same build that was scanned)
      │     ├── Image pushed to ACR
      │     └── Digest validated post-push
      │
      └── Stage 3: Deploy to Container Apps
            └── Approval gate → az containerapp update

Runtime (eastus2)
  ca-fastapi (user-assigned identity)
    └── cae-project2, in snet-containers (vnet-workloads spoke)
          └── private endpoint in snet-compute ──► kv-ado-project2
                DNS: privatelink.vaultcore.azure.net (landing zone hub)
```

## Design Decisions

**GitHub as source, ADO as orchestrator.** Many enterprises already use both platforms. GitHub handles collaboration, code review, early scanning and dependency updates. ADO handles pipeline execution, environment approvals, and the audit trail.

**Build once, scan, push the same artifact.** The Docker image is built exactly once in Stage 1, saved with `docker save`, and loaded in Stage 2 with `docker load` before being pushed to ACR. The image Trivy scanned is the image pushed to the registry. Rebuilding in the push stage would produce a different digest and break that guarantee.

**No stored credentials.** The ADO-to-Azure service connection uses workload identity federation. The Container App pulls from ACR and reads Key Vault with a user-assigned managed identity. No client secrets or passwords exist anywhere in the pipeline or the infrastructure code.

**User-assigned identity, granted before the app exists.** The identity is created first and given `AcrPull` on the registry and `Key Vault Secrets User` on the vault, each scoped to that one resource. Only then is the Container App created. A system-assigned identity only exists after the app is created, so its first revision would start before its permissions existed.

**Key Vault reachable privately by the app.** The Container Apps environment is integrated into the landing zone's `vnet-workloads` spoke. The vault has a private endpoint in `snet-compute`, registered in the hub's `privatelink.vaultcore.azure.net` zone, which is linked to the spoke. The vault's public endpoint stays enabled only for administration: default action Deny, with a single IP rule for the deployer (`deployment_ip`). Container Apps is not a Key Vault trusted service, so without the private endpoint the app could not read the secret.

**Secret values never in code or state.** Terraform creates `app-secret` with an obvious placeholder and `lifecycle { ignore_changes = [value] }`. The real value is set out-of-band with `az keyvault secret set`. The Container App references the secret by its versionless ID, so rotating the value needs no Terraform change.

**Trivy gate on fixable vulnerabilities.** The gate fails on any CRITICAL or HIGH finding that has a published fix (`--ignore-unfixed`). A second, non-blocking scan reports every CRITICAL and HIGH finding on each run, so unfixed CVEs stay visible. When a vendor publishes a fix, the finding's status changes to fixed and the gate fails until the image is rebuilt with the patch.

**Hardened runtime image.** The Dockerfile upgrades Debian packages at build time and removes pip after installing dependencies. pip is only needed at build time, and its bundled copies of urllib3, msgpack and setuptools carried HIGH CVEs.

**Reproducible dependencies.** `app/requirements.in` lists the direct dependencies. `app/requirements.txt` is a pip-compile lockfile that pins every package, including transitive ones. Any change to the dependency tree, including a newly introduced package, appears as a reviewable diff.

**Approval gate on production.** The deployment stage uses an ADO environment with a required approval check, mirroring enterprise change control.

**Azure Container Apps over AKS.** The application is a stateless FastAPI service. It does not need a full Kubernetes cluster. Container Apps reduces cost and operational complexity.

**Self-hosted agent, with scanning that does not depend on it.** ADO runs on a self-hosted agent in the Default pool, because Microsoft-hosted agents are not available in this organisation. The agent machine is not always on, so the GitHub Actions `security-scan` workflow scans every PR and runs weekly on GitHub-hosted runners regardless. Because the agent keeps Docker layers between runs, ADO builds use `--pull --no-cache`, so the base image and the OS patch step are always fresh.

**Landing zone integration.** The project consumes the landing zone's network through data sources and never manages it. For the duration of this project, `snet-containers` in the landing zone is delegated to `Microsoft.App/environments` instead of Container Instances. That change lives in the landing zone repository and is reverted when this project is retired.

## Repository Structure

```
azure-ado-delivery-pipeline/
  app/                          # FastAPI application
    main.py
    requirements.in             # direct dependencies
    requirements.txt            # pip-compile lockfile (generated)
    Dockerfile
  infra/                        # Terraform for Azure infrastructure
    main.tf
    variables.tf
    outputs.tf
    backend.tf
    versions.tf
    terraform.tfvars.example
  .azure/                       # ADO pipeline definition
    pipeline.yml
  .github/
    dependabot.yml              # weekly dependency update PRs
    workflows/
      security-scan.yml         # PR and weekly Trivy scans
  README.md
```

## Infrastructure

All project resources are provisioned via Terraform in a dedicated resource group. Remote state is stored in the platform state storage account, following the landing zone project's pattern.

| Resource                   | Name                       | Purpose                                                                  |
| -------------------------- | -------------------------- | ------------------------------------------------------------------------ |
| Resource Group             | rg-project2                | Contains all project resources                                           |
| Azure Container Registry   | acrproject2                | Stores container images                                                  |
| User-assigned identity     | id-ca-fastapi              | Used by the Container App for ACR pull and Key Vault access              |
| Container Apps Environment | cae-project2               | Workload profiles (Consumption), in `snet-containers`, logs to central Log Analytics |
| Container App              | ca-fastapi                 | Deployment target                                                        |
| Key Vault                  | kv-ado-project2            | Stores `app-secret`; RBAC authorisation; public access limited to the deployer IP |
| Private endpoint           | pe-kv-ado-project2         | Private path from the spoke to the vault                                 |

Consumed from the landing zone (read-only data sources): `vnet-workloads`, `snet-containers`, `snet-compute`, the `privatelink.vaultcore.azure.net` zone, and the `law-platform` Log Analytics workspace.

**Note on the initial Container App image.** Terraform provisions the Container App with a Microsoft placeholder image (`mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`), because the application image does not exist in ACR until the pipeline runs. The placeholder does not expose the app's endpoints, so the app is not testable until the first pipeline deployment replaces it via `az containerapp update`.

**Note on provisioning time.** A Container Apps environment integrated into a VNet commonly takes 15 to 30 minutes or more to create. The environment resource has a 60-minute create timeout so Terraform does not give up before Azure finishes.

## Pipeline Configuration

The pipeline references a variable group named `project2-vars` defined in ADO Library.

| Variable           | Value                  |
| ------------------ | ---------------------- |
| ACR_NAME           | acrproject2            |
| ACR_LOGIN_SERVER   | acrproject2.azurecr.io |
| RESOURCE_GROUP     | rg-project2            |
| CONTAINER_APP_NAME | ca-fastapi             |
| APP_ENV            | production             |
| APP_REGION         | eastus2                |

The ADO service connection to Azure uses workload identity federation scoped to the subscription. The GitHub service connection uses OAuth.

Trivy is pinned to the same version (`0.69.3`) in the ADO pipeline and the GitHub Actions workflow, so both gates evaluate findings the same way. Upgrade both together.

## Running from Scratch

### Prerequisites

- Azure subscription with Contributor access
- The landing zone deployed: `vnet-workloads` with `snet-containers` delegated to `Microsoft.App/environments`, `snet-compute`, and the hub `privatelink.vaultcore.azure.net` zone linked to the spoke
- Azure DevOps organisation at dev.azure.com/moshstaq
- GitHub repository cloned
- Terraform 1.x installed
- Azure CLI authenticated
- Self-hosted agent with Docker, Azure CLI, and curl installed and registered to the Default pool in ADO

### 1. Provision infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Set deployment_ip to your current public IP: curl -s https://api.ipify.org
terraform init
terraform apply      # the Container Apps environment can take 15-30+ minutes
```

If Terraform fails with `ForbiddenByFirewall` on the Key Vault, your public IP has changed. Update `deployment_ip` and apply again.

### 2. Set the secret value

Terraform only creates a placeholder. Set the real value after every fresh apply:

```bash
az keyvault secret set --vault-name kv-ado-project2 --name app-secret --value "<value>" -o none
```

### 3. Configure ADO

Create a variable group named `project2-vars` in ADO Library with the variables listed above.

Create an environment named `production` in ADO Pipelines and add an approval check.

Create a service connection named `azure-rm` using workload identity federation scoped to the subscription.

### 4. Create the pipeline

In ADO, create a new pipeline pointing to this repository and select `.azure/pipeline.yml` as the definition file.

### 5. Run and verify

Push a change to main. The pipeline triggers automatically. Approve the deployment gate in ADO when Stage 2 completes. Then:

```bash
FQDN=$(az containerapp show -n ca-fastapi -g rg-project2 --query properties.configuration.ingress.fqdn -o tsv)
curl -s https://$FQDN/health
curl -s https://$FQDN/info
curl -s https://$FQDN/secret-check   # expect "secret_mounted": true
```

### Tear down

```bash
cd infra
terraform destroy
```

When the project is retired for good, revert the `snet-containers` delegation in the landing zone.

## Updating Dependencies

Edit `app/requirements.in`, then regenerate the lockfile:

```bash
cd app
docker run --rm -v "$PWD":/w -w /w python:3.15.2-slim-trixie \
  sh -c "pip install -q pip-tools && pip-compile requirements.in -o requirements.txt"
```

Commit both files. Dependabot opens these PRs automatically each week.

## Application

The FastAPI application exposes three endpoints:

- `GET /health` returns service status and version
- `GET /info` returns the application name, environment, and region sourced from environment variables
- `GET /secret-check` confirms that the Key Vault secret is correctly injected via the Container App's managed identity

A successful `/secret-check` response validates the full chain end to end: the user-assigned identity holds `Key Vault Secrets User`, the private endpoint and DNS resolve the vault privately, and the secret reference resolves at runtime. Because the vault's firewall admits only the deployer's IP, a successful response also proves the app reached the vault over the private endpoint.

## Related Repositories

| Repository         | Relationship                                                     |
| ------------------ | ---------------------------------------------------------------- |
| stratum-platform   | Internal developer platform, the current focus of this portfolio |
| azure-landing-zone | Azure platform foundation; provides the network this project uses |
| aws-landing-zone   | AWS platform foundation                                          |
