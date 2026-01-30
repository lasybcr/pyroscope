# Terraform Deployment

Manages the same Docker containers as `docker-compose.yml` using the
[kreuzwerker/docker](https://registry.terraform.io/providers/kreuzwerker/docker/latest)
Terraform provider. Use this when you want state-tracked, declarative
infrastructure or plan to extend to remote Docker hosts / cloud VMs.

## Prerequisites

- Terraform >= 1.0
- Docker running locally
- Pre-built app image: `docker compose build vertx-app` (from project root)

## Usage

```bash
# 1. Build the app image first (Terraform references it, doesn't build it)
cd /path/to/pyroscope
docker compose build vertx-app

# 2. Tag for Terraform
docker tag pyroscope-vertx-app:latest pyroscope-vertx-app:latest

# 3. Deploy
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set project_dir to your absolute path
terraform init
terraform apply

# 4. Tear down
terraform destroy
```

## When to use this vs scripts

| Approach | Best for |
|----------|----------|
| `bash scripts/deploy.sh` | Quick local demo, CI smoke tests |
| `terraform apply` | Reproducible infra, remote Docker hosts, drift detection |
| `ansible-playbook` | Multi-host provisioning, config management |
