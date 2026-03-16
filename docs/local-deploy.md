# local-deploy.sh

A CLI tool for deploying and testing Docker Swarm stacks locally in Vagrant VMs without pushing to GitHub. It simulates the full SwarmCD GitOps pipeline by syncing the local working tree to a bare Git repository on the VM, served via `git-daemon`.

## Prerequisites

### Host Requirements

| Requirement | Purpose |
|---|---|
| **libvirt** | VM hypervisor (used by Vagrant via the libvirt provider) |
| **Vagrant** | VM management (libvirt provider) |
| **sops** | Decrypts age-encrypted secrets (e.g. `secrets/age.key`) |
| **virtiofs support** | `/etc/libvirt/qemu.conf` must set `memory_backing_dir = "/dev/shm"` |

### Project Files

| File | Required | Purpose |
|---|---|---|
| `secrets/age.key` | Yes (for `full`/`reset`) | SOPS-encrypted age private key; decrypted at runtime to create the `sops_age_key` Docker secret |
| `apps/swarm-cd/compose.yaml` | Yes | Base SwarmCD stack definition |
| `apps/swarm-cd/compose.local.yaml` | Yes (for `full`/`sync`) | Contains the local SwarmCD image override; patched into `compose.yaml` at deploy time |
| `apps/swarm-cd/repos.local.yaml` | Yes (for `full`/`sync`) | Local repo config; copied to `repos.yaml` at deploy time, pointing to `git://172.17.0.1/swarm-git-ops.git` |

### VM State

The script targets **swarm01** (the Swarm manager node). On first run:

1. The VM is started and provisioned if needed (`vagrant up` + `vagrant provision`).
2. A bare Git repo is created at `/srv/git/swarm-git-ops.git` (cloned from the virtiofs-mounted `/repo`).
3. A `git-daemon` systemd service exposes the bare repo via the `git://` protocol.
4. The `sops_age_key` Docker secret is created from the decrypted age key.

## Architecture

```
Host                              VM (swarm01)
─────────────────────────────────────────────────────
working tree ──virtiofs──→ /repo
                              │
              sync_repo()     ▼
                         /srv/git/swarm-git-ops.git
                              │
              git-daemon      ▼
                         git://172.17.0.1/...
                              │
              SwarmCD polls   ▼
                         docker stack deploy
```

The local working tree (including uncommitted changes) is mounted into the VM at `/repo` via virtiofs. The `sync` step fetches from `/repo` into the bare repo, which `git-daemon` serves. SwarmCD then pulls from `git-daemon` exactly as it would from GitHub in production.

> **Note:** Uncommitted and staged changes are automatically included. The script creates a temporary commit before syncing and removes it afterwards, so your working tree is left unchanged. The distinction between staged and unstaged changes is lost after sync (everything becomes unstaged).

## Commands

### `full`

Runs the complete local GitOps pipeline:

1. **check_vm**: Ensures swarm01 is running; starts and provisions it if not.
2. **apply_local_overrides**: Copies `repos.local.yaml` → `repos.yaml` and patches the SwarmCD image from `compose.local.yaml` into `compose.yaml`. These changes are reverted after deployment.
3. **sync_repo**: Creates a temporary commit if uncommitted changes exist, fetches all branches from `/repo` into the bare repo, undoes the temporary commit; starts `git-daemon` if inactive.
4. **push_local_image**: If `compose.local.yaml` references a local Docker image (no registry prefix), transfers it to the VM via `docker save`/`docker load`.
5. **check_sops_secret**: Creates the `sops_age_key` Docker secret if missing.
6. **deploy_full**: Removes the existing `swarm-cd` stack (to refresh Docker configs), then redeploys with `compose.yaml` (which now contains the local overrides).
7. **show_status**: Prints nodes, stacks, and services.

```bash
scripts/local-deploy.sh full         # full deploy
scripts/local-deploy.sh full -f      # full deploy + follow logs
```

### `stack <name>`

Deploys a single stack directly, bypassing SwarmCD:

1. Syncs the repo.
2. Decrypts any `secret_*` files in the stack directory and creates Docker secrets.
3. Runs `docker stack deploy` with the stack's `compose.yaml`.

```bash
scripts/local-deploy.sh stack caddy
```

### `sync`

Applies local overrides, syncs the repo to the VM bare repo, then reverts the overrides. Does not deploy anything. Useful for preparing changes before a SwarmCD poll cycle picks them up.

```bash
scripts/local-deploy.sh sync
```

### `status`

Shows current cluster state: nodes, stacks, and services.

```bash
scripts/local-deploy.sh status
```

### `reset`

Ensures the `sops_age_key` Docker secret exists, removes the local SwarmCD stack, and redeploys with the original `compose.yaml` only (GitHub remote). Use this to switch back to production-like behavior.

```bash
scripts/local-deploy.sh reset
```

### `logs [service]`

Tails logs for a service. Defaults to `swarm-cd_swarm-cd`.

```bash
scripts/local-deploy.sh logs                   # SwarmCD logs
scripts/local-deploy.sh logs caddy_caddy       # specific service
```

## Options

| Flag | Description |
|---|---|
| `-f`, `--follow` | Follow logs after deployment (works with `full` and `stack`) |
| `-h`, `--help` | Show usage help |

## Secret Handling

For the `stack` command, the script handles SOPS secrets automatically:

1. Scans for files matching `secret_*` in the stack directory.
2. For each secret file, derives a Docker secret name: `<stack>_<suffix>` (e.g. `syncthing4swarm_stguiapikey` from `secret_stguiapikey`).
3. Skips secrets that already exist; decrypts and creates new ones via `sops -d`.

For `full`/`reset`, only the global `sops_age_key` secret is managed (SwarmCD handles per-stack secrets itself).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `swarm01 is not running` | VM stopped or destroyed | Script auto-starts it; if provisioning fails, run `vagrant up swarm01` manually |
| `compose.local.yaml not found` | Missing local override | Create it, see `apps/swarm-cd/compose.local.yaml` |
| `secrets/age.key not found` | Missing encrypted key | Provide the SOPS-encrypted age key at `secrets/age.key` |
| `sops not found` | sops not installed on host | Install sops (`pacman -S sops` or equivalent) |
| Stacks not deploying after `full` | SwarmCD polls every 120s | Wait or check logs with `scripts/local-deploy.sh logs` |
| Changes not visible after sync | Temporary commit failed | Check `git status` for conflicts or issues preventing `git add -A` |
