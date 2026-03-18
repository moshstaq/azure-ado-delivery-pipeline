# azure-ado-delivery-pipeline

A production-pattern CI/CD pipeline using Azure DevOps as the orchestration layer, GitHub as the source control platform, and Azure Container Apps as the deployment target.

## Overview

This project demonstrates a common enterprise architecture where GitHub hosts the source code and Azure DevOps governs the delivery process. The two platforms are connected via a service connection, keeping developer collaboration separate from deployment orchestration.

The pipeline enforces a delivery process rather than just running automation. No code reaches the deployment stage without passing a vulnerability scan, and no deployment occurs without explicit approval.

## Architecture

```
GitHub Repository
      │
      │  trigger (push to main)
      ▼
Azure DevOps Pipeline
      │
      ├── Stage 1: Build and Scan
      │     ├── Docker build
      │     ├── Trivy scan (blocks on CRITICAL/HIGH CVEs)
      │     └── Image saved as pipeline artifact
      │
      ├── Stage 2: Push to ACR
      │     ├── Image loaded from artifact (same build that was scanned)
      │     ├── Image pushed to ACR
      │     └── Digest validated post-push
      │
      └── Stage 3: Deploy to Container Apps
            └── Approval gate → az containerapp update
```

## Design Decisions

**GitHub as source, ADO as orchestrator.** Many enterprises already use both platforms. Separating source control from delivery governance means each platform does what it does best. GitHub handles collaboration and code review. ADO handles pipeline execution, environment approvals, and the audit trail.

**Build once, scan, push the same artifact.** The Docker image is built exactly once in Stage 1. The built image is saved as a pipeline artifact using `docker save` and loaded in Stage 2 using `docker load` before being pushed to ACR. This guarantees that the image scanned by Trivy is identical to the image pushed to the registry. Rebuilding in the push stage, a common pattern in simpler pipelines, breaks this guarantee because a second build produces a different image digest.

**Workload identity federation throughout.** Both the ADO-to-Azure service connection and the Container App-to-ACR pull use managed identities with federated credentials. No client secrets or stored passwords exist anywhere in this pipeline.

**Key Vault wired to the Container App at runtime.** The Container App uses its system-assigned managed identity to read a secret from Key Vault. The secret is injected as an environment variable at runtime via a Container Apps secret reference. The `/secret-check` endpoint confirms that the secret is present and correctly sourced. This validates the end-to-end identity and secrets chain, not just the infrastructure provisioning.

**Trivy scan as a hard gate.** The pipeline fails at Stage 1 if any CRITICAL or HIGH severity vulnerabilities are found in the image. This was validated during development when a real CVE (CVE-2024-47874 in starlette 0.38.6) was detected and resolved before the pipeline was allowed to proceed.

**Approval gate on production.** The deployment stage uses an ADO environment with a required approval check. This mirrors the change control process in enterprise environments and ensures a human decision point exists before every production deployment.

**Azure Container Apps over AKS.** The application is a stateless FastAPI service. It does not require the overhead of a full Kubernetes cluster. Container Apps is the appropriate target and significantly reduces infrastructure cost and operational complexity.

**Self-hosted agent.** The pipeline uses a self-hosted agent pool named Default. This was a deliberate choice given the unavailability of Microsoft-hosted agents in this environment. Self-hosted agent registered to the Default pool in ADO. The agent runs on a local development machine with Docker and the Azure CLI already present as part of the standard development environment for this project.

## Repository Structure

```
azure-ado-delivery-pipeline/
  app/                        # FastAPI application
    main.py
    requirements.txt
    Dockerfile
  infra/                      # Terraform for Azure infrastructure
    main.tf
    variables.tf
    outputs.tf
    backend.tf
    versions.tf
    terraform.tfvars.example
  .azure/                     # ADO pipeline definition
    pipeline.yml
  README.md
```

## Infrastructure

All resources are provisioned via Terraform in a dedicated resource group. Remote state is stored in the existing platform state storage account following the same pattern established in the landing zone project.

| Resource                   | Name            | Purpose                                                 |
| -------------------------- | --------------- | ------------------------------------------------------- |
| Resource Group             | rg-project2     | Contains all project resources                          |
| Azure Container Registry   | acrproject2     | Stores container images                                 |
| Container Apps Environment | cae-project2    | Hosts the Container App, logs to central Log Analytics  |
| Container App              | ca-fastapi      | Deployment target with system-assigned managed identity |
| Key Vault                  | kv-ado-project2 | Stores the app-secret referenced at runtime             |

**Note on the initial Container App image.** Terraform provisions the Container App with a Microsoft placeholder image (`mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`). This is intentional: the application image does not exist in ACR until the pipeline runs for the first time. The placeholder allows Terraform to complete successfully. The pipeline immediately replaces it on the first successful run via `az containerapp update`.

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

## Running from Scratch

### Prerequisites

- Azure subscription with Contributor access
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
terraform apply
```

### 2. Configure ADO

Create a variable group named `project2-vars` in ADO Library with the variables listed above.

Create an environment named `production` in ADO Pipelines and add an approval check.

Create a service connection named `azure-rm` using workload identity federation scoped to the subscription.

### 3. Create the pipeline

In ADO, create a new pipeline pointing to this repository and select `.azure/pipeline.yml` as the definition file.

### 4. Run

Push a change to main. The pipeline triggers automatically. Approve the deployment gate in ADO when Stage 2 completes.

## Application

The FastAPI application exposes three endpoints:

- `GET /health` returns service status and version
- `GET /info` returns the application name, environment, and region sourced from environment variables
- `GET /secret-check` confirms that the Key Vault secret is correctly injected via the Container App managed identity

The `/secret-check` endpoint validates the full identity and secrets chain end to end. A successful response confirms that the Container App system-assigned managed identity has been granted Key Vault Secrets User, the secret reference is correctly configured in the Container App, and the secret value is available to the application at runtime.
