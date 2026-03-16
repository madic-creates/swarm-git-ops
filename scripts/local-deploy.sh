#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM="swarm01"
BARE_REPO="/srv/git/swarm-git-ops.git"
MOUNTED_REPO="/repo"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
die()   { err "$@"; exit 1; }

ssh_cmd() {
  local output rc
  output=$(vagrant ssh "$VM" -- "$@" 2>&1)
  rc=$?
  printf '%s\n' "$output" | { grep -v '^Starting with UID:' || true; } | tr -d '\r'
  return "$rc"
}

# Streaming variant, unbuffered, for logs and follow mode
ssh_stream() { vagrant ssh "$VM" -- "$@"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Deploy and test stacks locally in Vagrant without pushing to GitHub.

Commands:
  full              Sync repo to VM + redeploy SwarmCD pointing at local git daemon
  stack <name>      Deploy a single stack via docker stack deploy (bypasses SwarmCD)
  sync              Sync repo to VM bare repo only (no deploy, waits for SwarmCD poll)
  status            Show cluster nodes, stacks, and service replicas
  reset             Remove local SwarmCD and redeploy with GitHub remote
  logs [service]    Tail logs (default: swarm-cd_swarm-cd)

Options:
  -f, --follow      Follow logs after deployment
  -h, --help        Show this help

Examples:
  $(basename "$0")                    # Show this help
  $(basename "$0") full               # Full GitOps deploy via local git daemon
  $(basename "$0") stack caddy        # Deploy only the caddy stack
  $(basename "$0") sync               # Sync repo without deploying
  $(basename "$0") reset              # Switch back to GitHub
  $(basename "$0") logs               # Tail SwarmCD logs
  $(basename "$0") logs caddy_caddy   # Tail caddy service logs
EOF
}

# --- Preflight checks ---

check_vm() {
  info "Checking VM status..."
  local state
  state=$(vagrant status "$VM" --machine-readable 2>&1 \
    | grep -v '^Starting with UID:' | tr -d '\r' \
    | grep ",state," | tail -1 | cut -d',' -f4 || true)

  if [[ "$state" != "running" ]]; then
    warn "$VM is not running (state: ${state:-unknown}). Starting it..."
    vagrant up --no-provision "$VM" || die "Failed to start $VM"

    if ! ssh_cmd "command -v docker" &>/dev/null; then
      info "VM not yet provisioned. Running provisioning (this may take a while)..."
      vagrant provision "$VM" || die "Provisioning failed"
    fi
  fi
  ok "$VM is running"
}

check_sops_secret() {
  local secret_id
  secret_id=$(ssh_cmd "docker secret ls --filter name=sops_age_key --quiet" 2>/dev/null || true)

  if [[ -z "$secret_id" ]]; then
    info "Docker secret 'sops_age_key' does not exist. Creating..."

    local key_file="$REPO_ROOT/secrets/age.key"
    [[ -f "$key_file" ]] || die "secrets/age.key not found. Cannot create sops_age_key secret."
    command -v sops &>/dev/null || die "sops not found. Install sops to decrypt secrets."

    local tmp_file="$REPO_ROOT/.sops_age_key.tmp"
    trap 'rm -f "$tmp_file"' RETURN
    sops -d "$key_file" > "$tmp_file" || die "Failed to decrypt secrets/age.key"

    ssh_cmd "docker secret create sops_age_key $MOUNTED_REPO/.sops_age_key.tmp" \
      || die "Failed to create Docker secret"
    rm -f "$tmp_file"
    trap - RETURN

    ok "Docker secret 'sops_age_key' created"
  else
    ok "Docker secret 'sops_age_key' exists"
  fi
}

# --- Core functions ---

apply_local_overrides() {
  local compose_local="$REPO_ROOT/apps/swarm-cd/compose.local.yaml"
  local repos_local="$REPO_ROOT/apps/swarm-cd/repos.local.yaml"

  if [[ ! -f "$compose_local" ]]; then
    die "apps/swarm-cd/compose.local.yaml not found. Create it first (see README)."
  fi

  info "Applying local overrides to repo files..."

  # Apply repos.local.yaml → repos.yaml
  if [[ -f "$repos_local" ]]; then
    cp "$repos_local" "$REPO_ROOT/apps/swarm-cd/repos.yaml"
  fi

  # Apply image override from compose.local.yaml
  local image
  image=$(grep 'image:' "$compose_local" | head -1 | awk '{print $2}')
  if [[ -n "$image" ]]; then
    sed -i "s|image: ghcr.io/m-adawi/swarm-cd:.*|image: $image|" "$REPO_ROOT/apps/swarm-cd/compose.yaml"
  fi

  ok "Local overrides applied (repos.yaml + compose.yaml)"
}

revert_local_overrides() {
  git -C "$REPO_ROOT" checkout -- apps/swarm-cd/repos.yaml apps/swarm-cd/compose.yaml 2>/dev/null || true
  info "Local overrides reverted"
}

sync_repo() {
  info "Syncing local repo to VM bare repo..."

  # Create bare repo if it doesn't exist (owned by root for git-daemon)
  if ! ssh_cmd "test -d $BARE_REPO" 2>/dev/null; then
    info "Creating bare repo at $BARE_REPO..."
    ssh_cmd "sudo mkdir -p /srv/git && sudo git clone --bare $MOUNTED_REPO $BARE_REPO"
  fi

  # Ensure bare repo is owned by root (git-daemon runs as root)
  ssh_cmd "sudo chown -R root:root $BARE_REPO" 2>/dev/null

  # Include uncommitted changes via temporary commit
  local temp_commit=false
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    warn "Uncommitted changes detected. Creating temporary commit for sync..."
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" commit --no-verify -m "tmp: local-deploy sync (uncommitted changes)" >/dev/null
    temp_commit=true
  fi

  # Ensure temp commit is always undone, even on error
  _undo_temp_commit() {
    if [[ "$temp_commit" == true ]]; then
      git -C "$REPO_ROOT" reset --mixed HEAD~1 >/dev/null 2>&1
      temp_commit=false
      info "Temporary commit removed, working tree restored"
    fi
  }
  trap _undo_temp_commit RETURN

  # Fetch latest from mounted repo (sudo because bare repo is owned by root)
  ssh_cmd "sudo git -C $BARE_REPO fetch $MOUNTED_REPO '+refs/heads/*:refs/heads/*' --prune" 2>/dev/null

  local commit
  commit=$(ssh_cmd "sudo git -C $BARE_REPO rev-parse --short HEAD" 2>/dev/null)
  ok "Bare repo updated (HEAD: ${commit})"

  # Ensure git daemon is running
  local daemon_status
  daemon_status=$(ssh_cmd "systemctl is-active git-daemon" 2>/dev/null || echo "inactive")

  if [[ "$daemon_status" != "active" ]]; then
    warn "git-daemon is not running, starting..."
    ssh_cmd "sudo systemctl start git-daemon"
  fi
  ok "git-daemon is active"
}

push_local_image() {
  local compose_local="$REPO_ROOT/apps/swarm-cd/compose.local.yaml"
  local image
  image=$(grep 'image:' "$compose_local" | head -1 | awk '{print $2}')
  [[ -n "$image" ]] || return 0

  # Skip if it's a remote image (contains a registry slash)
  if [[ "$image" == *"/"* ]]; then
    return 0
  fi

  # Check if image exists locally
  if ! docker image inspect "$image" &>/dev/null; then
    die "Local image '$image' not found. Build it first."
  fi

  # Check if image already exists on VM
  if ssh_cmd "docker image inspect $image" &>/dev/null; then
    ok "Image '$image' already present on VM"
    return 0
  fi

  info "Transferring image '$image' to VM..."
  local tar_file="$REPO_ROOT/tmp/swarm-cd-image.tar"
  mkdir -p "$REPO_ROOT/tmp"
  docker save "$image" -o "$tar_file"
  ssh_cmd "docker load -i $MOUNTED_REPO/tmp/swarm-cd-image.tar"
  rm -f "$tar_file"
  ok "Image '$image' loaded on VM"
}

deploy_full() {
  info "Deploying SwarmCD with local git repo..."

  check_sops_secret || exit 1
  push_local_image

  # Remove existing swarm-cd stack to refresh Docker configs
  local existing
  existing=$(ssh_cmd "docker stack ls --format '{{.Name}}'" 2>/dev/null | grep -w "swarm-cd" || true)

  if [[ -n "$existing" ]]; then
    info "Removing existing swarm-cd stack..."
    ssh_cmd "docker stack rm swarm-cd"
    info "Waiting for cleanup..."
    sleep 5
  fi

  # Deploy from mounted repo (which has local overrides applied)
  info "Deploying swarm-cd with local overrides..."
  ssh_cmd "cd $MOUNTED_REPO/apps/swarm-cd && docker stack deploy -c compose.yaml swarm-cd"
  ok "SwarmCD deployed with local git daemon URL"

  echo ""
  warn "SwarmCD polls every 120s. Stacks will be deployed gradually."
  info "Watch progress: $0 logs"
}

deploy_stack() {
  local stack_name="$1"
  local compose_file="$MOUNTED_REPO/apps/$stack_name/compose.yaml"

  # Verify the stack directory exists on the VM
  if ! ssh_cmd "test -f $compose_file" 2>/dev/null; then
    die "Stack '$stack_name' not found at apps/$stack_name/compose.yaml"
  fi

  # Handle SOPS-encrypted secrets
  local secrets
  secrets=$(ssh_cmd "ls $MOUNTED_REPO/apps/$stack_name/secret_* 2>/dev/null" || true)

  if [[ -n "$secrets" ]]; then
    info "Decrypting secrets for $stack_name..."
    ssh_cmd "cd $MOUNTED_REPO/apps/$stack_name && for f in secret_*; do
      name=\"${stack_name}_\$(echo \"\$f\" | sed 's/secret_//' | tr '-' '_')\"
      if docker secret inspect \"\$name\" >/dev/null 2>&1; then
        echo \"  Secret \$name already exists, skipping\"
      else
        sops -d \"\$f\" | docker secret create \"\$name\" - && echo \"  Created secret \$name\"
      fi
    done"
  fi

  info "Deploying stack '$stack_name'..."
  ssh_cmd "docker stack deploy -c $compose_file $stack_name"
  ok "Stack '$stack_name' deployed"
}

show_status() {
  echo ""
  echo -e "${CYAN}=== Cluster Status ===${NC}"
  echo ""

  info "Nodes:"
  ssh_cmd "docker node ls" 2>/dev/null || warn "Could not list nodes"

  echo ""
  info "Stacks:"
  ssh_cmd "docker stack ls" 2>/dev/null || warn "Could not list stacks"

  echo ""
  info "Services:"
  ssh_cmd "docker service ls --format 'table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}'" 2>/dev/null \
    || warn "Could not list services"
}

reset_to_github() {
  info "Switching SwarmCD back to GitHub..."

  local existing
  existing=$(ssh_cmd "docker stack ls --format '{{.Name}}'" 2>/dev/null | grep -w "swarm-cd" || true)

  if [[ -n "$existing" ]]; then
    ssh_cmd "docker stack rm swarm-cd"
    info "Waiting for cleanup..."
    sleep 5
  fi

  ssh_cmd "cd $MOUNTED_REPO/apps/swarm-cd && docker stack deploy -c compose.yaml swarm-cd"
  ok "SwarmCD deployed with GitHub remote"
}

tail_logs() {
  local service="${1:-swarm-cd_swarm-cd}"
  info "Tailing logs for $service..."
  ssh_stream "docker service logs -f --tail 50 $service"
}

# --- Main ---

cd "$REPO_ROOT"

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

COMMAND="$1"
FOLLOW=false

# Parse flags from remaining args
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--follow) FOLLOW=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           break ;;
  esac
done

case "$COMMAND" in
  -h|--help)
    usage
    exit 0
    ;;
  full)
    check_vm
    apply_local_overrides
    trap revert_local_overrides EXIT
    sync_repo
    deploy_full
    revert_local_overrides
    trap - EXIT
    show_status
    if [[ "$FOLLOW" == true ]]; then
      echo ""
      tail_logs
    fi
    ;;
  stack)
    STACK_NAME="${1:?Usage: $0 stack <name>}"
    check_vm
    sync_repo
    deploy_stack "$STACK_NAME"
    show_status
    if [[ "$FOLLOW" == true ]]; then
      echo ""
      tail_logs "${STACK_NAME}_${STACK_NAME}"
    fi
    ;;
  sync)
    check_vm
    apply_local_overrides
    trap revert_local_overrides EXIT
    sync_repo
    revert_local_overrides
    trap - EXIT
    ok "Sync complete. SwarmCD will pick up changes on next poll."
    ;;
  status)
    check_vm
    show_status
    ;;
  reset)
    check_vm
    check_sops_secret || exit 1
    reset_to_github
    ;;
  logs)
    check_vm
    tail_logs "${1:-swarm-cd_swarm-cd}"
    ;;
  *)
    err "Unknown command: $COMMAND"
    usage
    exit 1
    ;;
esac
