# azure-ado-delivery-pipeline

A production-pattern CI/CD pipeline using Azure DevOps as the orchestration layer, GitHub as the source control platform, and Azure Container Apps as the deployment target.

## Overview

This project demonstrates a common enterprise architecture where GitHub hosts the source code and Azure DevOps governs the delivery process. The two platforms are connected via a service connection, keeping developer collaboration separate from deployment orchestration.

The pipeline enforces a delivery process rather than just running automation. No code reaches the deployment stage without passing a vulnerability scan, and no deployment occurs without explicit approval.

## Architecture

```
GitHub Repository
      │
      │  trigger (push / PR)
      ▼
Azure DevOps Pipeline
      │
      ├── Stage 1: Build and Scan
      │     └── Docker build + Trivy scan (blocks on CRITICAL/HIGH CVEs)
      │
      ├── Stage 2: Push to ACR
      │     └── Image push + digest validation
      │
      └── Stage 3: Deploy to Container Apps
            └── Approval gate → az containerapp update
```

## Design Decisions

**GitHub as source, ADO as orchestrator.** Many enterprises already use both platforms. Separating source control from delivery governance means each platform does what it does best. GitHub handles collaboration and code review. ADO handles pipeline execution, environment approvals, and the audit trail.

**Workload identity federation throughout.** Both the ADO-to-Azure service connection and the Container App-to-ACR pull use managed identities with federated credentials. No client secrets or stored passwords exist anywhere in this pipeline.

**Trivy scan as a hard gate.** The pipeline fails at Stage 1 if any CRITICAL or HIGH severity vulnerabilities are found in the image. This was validated during development when a real CVE (CVE-2024-47874 in starlette 0.38.6) was detected and resolved before the pipeline was allowed to proceed.

**Approval gate on production.** The deployment stage uses an ADO environment with a required approval check. This mirrors the change control process in enterprise environments and ensures a human decision point exists before every production deployment.

**Azure Container Apps over AKS.** The application is a stateless FastAPI service. It does not require the overhead of a full Kubernetes cluster. Container Apps is the appropriate target and significantly reduces infrastructure cost and operational complexity.

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
  .azure/                     # ADO pipeline definition
    pipeline.yml
  README.md
```

## Infrastructure

All resources are provisioned via Terraform in a dedicated resource group for clean teardown.

| Resource                   | Name            | Purpose                              |
| -------------------------- | --------------- | ------------------------------------ |
| Resource Group             | rg-project2     | Contains all project resources       |
| Azure Container Registry   | acrproject2     | Stores container images              |
| Container Apps Environment | cae-project2    | Hosts the Container App              |
| Container App              | ca-fastapi      | Deployment target                    |
| Key Vault                  | kv-ado-project2 | Secrets store for pipeline variables |

Terraform remote state is stored in an existing backend storage account following the same pattern as prior projects in this portfolio.

## Pipeline Configuration

The pipeline references a variable group named `project2-vars` defined in ADO Library. This group holds non-secret configuration values including the ACR name, resource group, and Container App name.

The ADO service connection to Azure uses workload identity federation scoped to the subscription. The GitHub service connection uses OAuth.

## Running from Scratch

### Prerequisites

- Azure subscription with contributor access
- Azure DevOps organisation at dev.azure.com/moshstaq
- GitHub repository forked or cloned
- Terraform 1.x installed
- Azure CLI authenticated

### 1. Provision infrastructure

```bash
cd infra
terraform init
terraform apply
```

### 2. Configure ADO

Create a variable group named `project2-vars` in ADO Library with the following variables:

| Variable           | Value                  |
| ------------------ | ---------------------- |
| ACR_NAME           | acrproject2            |
| ACR_LOGIN_SERVER   | acrproject2.azurecr.io |
| RESOURCE_GROUP     | rg-project2            |
| CONTAINER_APP_NAME | ca-fastapi             |
| APP_ENV            | production             |
| APP_REGION         | eastus2                |

Create an environment named `production` in ADO Pipelines and add an approval check.

### 3. Create the pipeline

In ADO, create a new pipeline pointing to this repository and select `.azure/pipeline.yml` as the definition file.

### 4. Run

Push a change to a branch, open a pull request to main, and the pipeline will trigger automatically. Approve the deployment gate in ADO when Stage 2 completes.

## Application

The FastAPI application exposes two endpoints:

- `GET /health` returns service status and version
- `GET /info` returns the application name, environment, and region

These values confirm the deployment is live and environment variables are correctly injected at runtime.
