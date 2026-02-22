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

## Initial deployment

### Prerequisites

- A Docker Swarm cluster (at least one manager node)
- Git clone of this repository on a manager node

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
