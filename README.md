# GitOps managed Docker Swarm Home Cluster

<div align="center">

[![pre-commit](https://img.shields.io/badge/pre--commit-enabled?logo=pre-commit&logoColor=white&style=for-the-badge&color=brightgreen)](https://github.com/pre-commit/pre-commit)

</div>

## Overview

This repository is a playground for my Docker Swarm Home Cluster.

It uses [SwarmCD](https://github.com/m-adawi/swarm-cd) as a GitOps platform to automate the deployment and keep the cluster in a consistent state.

SwarmCD manages itself via the app-of-apps pattern: its own stack definition, config, and stack list are stored in this Git repository. Changes to `apps/swarm-cd/stacks.yaml` (e.g. adding a new stack) triggers a self-redeployment of SwarmCD, which then picks up and deploys the new stacks.

## Repository structure

```
apps/
  swarm-cd/
    compose.yaml   # SwarmCD service definition
    config.yaml    # SwarmCD settings (poll interval, auto_rotate)
    repos.yaml     # Git repositories to watch
    stacks.yaml    # Stack definitions (including SwarmCD itself)
  <app-name>/
    compose.yaml   # Additional app stacks managed by SwarmCD
```

## Adding a new stack

1. Create a directory under `apps/<app-name>/` with a `compose.yaml`
2. Add the stack to `apps/swarm-cd/stacks.yaml`:

   ```yaml
   <app-name>:
     repo: swarm-git-ops
     branch: main
     compose_file: apps/<app-name>/compose.yaml
   ```

3. Commit and push. SwarmCD detects the config change, redeploys itself, and then deploys the new stack.

## Secret management

Secrets are managed with [SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age) encryption. SwarmCD has native SOPS support and automatically decrypts encrypted files before deploying stacks.

Two age keys are used:

- **Personal key** — for local development and as the sole key for encrypting the cluster age key backup in `secrets/age.key`
- **Cluster key** — used by SwarmCD on the cluster to decrypt SOPS-encrypted files

Both keys are listed as recipients in `.sops.yaml` for application secrets, so either key can decrypt them. The cluster key itself is stored SOPS-encrypted in `secrets/age.key` (encrypted only with the personal key) as a backup.

SwarmCD discovers SOPS-encrypted files automatically via `sops_secrets_discovery: true` in `config.yaml`. No per-stack `sops_files` configuration is needed.

## Initial deployment

### Prerequisites

- A Docker Swarm cluster (at least one manager node)
- Git clone of this repository on a manager node

### Create the SOPS age Docker secret

The cluster age private key must be provided to SwarmCD out-of-band via a Docker secret. This is a one-time bootstrap step.

**Via Vagrant** (decrypts the key locally, copies it through the synced folder):

```shell
sops -d secrets/age.key > shared/age.key
vagrant ssh swarm01 -- docker secret create sops_age_key /vagrant/age.key
rm shared/age.key
```

**Directly on a Swarm Manager Node:**

```shell
docker secret create sops_age_key /path/to/cluster-age-private-key.txt
```

### Bootstrap SwarmCD

On a **Swarm Manager Node**, clone the repo and deploy the SwarmCD stack:

```shell
git clone https://github.com/madic-creates/swarm-git-ops.git
cd swarm-git-ops/apps/swarm-cd
docker stack deploy --compose-file compose.yaml swarm-cd
```

This is the only manual deployment needed. After this initial bootstrap, SwarmCD manages itself and all stacks defined in `apps/swarm-cd/stacks.yaml` via Git.

### Verify

```shell
# Check that SwarmCD is running
docker service ls

# View SwarmCD logs
docker service logs swarm-cd_swarm-cd

# Access the SwarmCD UI
# http://<manager-node-ip>:8080
```
