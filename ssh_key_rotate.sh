#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SSH Key Rotation Script
# Revokes an old shared key, generates per-server keys, deploys them,
# and configures ~/.ssh/config for automatic key selection.
# =============================================================================

# --- Configuration -----------------------------------------------------------
# Edit these values or pass them as environment variables.

# Path to the OLD public key to revoke from all servers
OLD_PUB_KEY="${OLD_PUB_KEY:-$HOME/.ssh/id_rsa.pub}"

# SSH user for connecting to remote servers (used during deployment)
SSH_USER="${SSH_USER:-root}"

# Key type and bits for new keys
KEY_TYPE="${KEY_TYPE:-ed25519}"   # ed25519 recommended; use "rsa" if legacy needed
# RSA_BITS only applies if KEY_TYPE=rsa
RSA_BITS="${RSA_BITS:-4096}"

# Directory to store all generated keys
KEY_DIR="${KEY_DIR:-$HOME/.ssh/per-server}"

# File containing server list: one entry per line
# Format:  IP_OR_HOSTNAME  [optional_alias]  [optional_user]
# Example:
#   192.168.1.10  webserver  deploy
#   10.0.0.5      dbserver
#   myhost.example.com
SERVERS_FILE="${SERVERS_FILE:-./servers.txt}"

# Backup tag for ssh config
BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"

# --- Color helpers -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Preflight checks --------------------------------------------------------
if [[ ! -f "$SERVERS_FILE" ]]; then
    err "Server list not found: $SERVERS_FILE"
    echo "Create it with one server per line:"
    echo "  IP_OR_HOSTNAME  [alias]  [user]"
    exit 1
fi

if [[ ! -f "$OLD_PUB_KEY" ]]; then
    err "Old public key not found: $OLD_PUB_KEY"
    echo "Set OLD_PUB_KEY to the path of the public key you want to revoke."
    exit 1
fi

OLD_KEY_CONTENT="$(cat "$OLD_PUB_KEY")"
mkdir -p "$KEY_DIR"

# --- Read server list ---------------------------------------------------------
declare -a HOSTS=()
declare -A ALIASES=()
declare -A USERS=()

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blanks and comments
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    read -r host alias user <<< "$line"
    HOSTS+=("$host")
    ALIASES["$host"]="${alias:-$host}"
    USERS["$host"]="${user:-$SSH_USER}"
done < "$SERVERS_FILE"

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    err "No servers found in $SERVERS_FILE"
    exit 1
fi

info "Found ${#HOSTS[@]} server(s) to process."
echo ""

# --- Summary / confirmation ---------------------------------------------------
echo "Plan:"
echo "  1. Generate a new $KEY_TYPE key per server in $KEY_DIR/"
echo "  2. Deploy each new public key to the server"
echo "  3. Revoke the old shared key from each server"
echo "  4. Update ~/.ssh/config so SSH auto-selects the right key"
echo ""
printf "  %-30s %-20s %-10s\n" "HOST" "ALIAS" "USER"
printf "  %-30s %-20s %-10s\n" "----" "-----" "----"
for host in "${HOSTS[@]}"; do
    printf "  %-30s %-20s %-10s\n" "$host" "${ALIASES[$host]}" "${USERS[$host]}"
done
echo ""
read -rp "Proceed? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
echo ""

# --- Main loop ----------------------------------------------------------------
declare -a SUCCESS=()
declare -a FAILED=()

for host in "${HOSTS[@]}"; do
    alias="${ALIASES[$host]}"
    user="${USERS[$host]}"
    key_name="id_${KEY_TYPE}_${alias}"
    key_path="${KEY_DIR}/${key_name}"

    info "--- Processing: $host (alias: $alias, user: $user) ---"

    # 1. Generate new key (skip if already exists)
    if [[ -f "$key_path" ]]; then
        warn "Key already exists: $key_path — skipping generation."
    else
        info "Generating new $KEY_TYPE key..."
        if [[ "$KEY_TYPE" == "rsa" ]]; then
            ssh-keygen -t rsa -b "$RSA_BITS" -f "$key_path" -N "" -C "${user}@${alias}" -q
        else
            ssh-keygen -t "$KEY_TYPE" -f "$key_path" -N "" -C "${user}@${alias}" -q
        fi
        info "Key created: $key_path"
    fi

    NEW_PUB="$(cat "${key_path}.pub")"

    # 2. Deploy new key & revoke old key on the remote server
    #    This runs as a single SSH session using the OLD key (which still works).
    info "Deploying new key and revoking old key on $host..."

    # Build a remote script that is safe with special characters
    REMOTE_SCRIPT=$(cat <<'REMOTE_EOF'
set -e
AUTH_FILE="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"
touch "$AUTH_FILE"
chmod 700 "$HOME/.ssh"
chmod 600 "$AUTH_FILE"

# Add the new key if not already present
if ! grep -qF "$NEW_PUB" "$AUTH_FILE" 2>/dev/null; then
    echo "$NEW_PUB" >> "$AUTH_FILE"
    echo "  [remote] New key added."
else
    echo "  [remote] New key already present."
fi

# Remove the old key
if grep -qF "$OLD_KEY_CONTENT" "$AUTH_FILE" 2>/dev/null; then
    grep -vF "$OLD_KEY_CONTENT" "$AUTH_FILE" > "${AUTH_FILE}.tmp"
    mv "${AUTH_FILE}.tmp" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    echo "  [remote] Old key revoked."
else
    echo "  [remote] Old key not found (already removed?)."
fi
REMOTE_EOF
    )

    if ssh -o ConnectTimeout=10 \
           -o StrictHostKeyChecking=accept-new \
           -o BatchMode=yes \
           "${user}@${host}" \
           "NEW_PUB=$(printf '%q' "$NEW_PUB") OLD_KEY_CONTENT=$(printf '%q' "$OLD_KEY_CONTENT") bash -s" \
           <<< "$REMOTE_SCRIPT" 2>&1; then

        # 3. Verify the new key works
        info "Verifying new key..."
        if ssh -o ConnectTimeout=10 \
               -o BatchMode=yes \
               -i "$key_path" \
               "${user}@${host}" "echo '  [remote] New key works!'" 2>&1; then
            info "✓ $host complete."
            SUCCESS+=("$host")
        else
            warn "New key verification failed for $host. Old key may already be revoked!"
            FAILED+=("$host")
        fi
    else
        err "Could not connect to $host — skipping."
        FAILED+=("$host")
    fi
    echo ""
done

# --- Update ~/.ssh/config -----------------------------------------------------
info "Updating ~/.ssh/config..."

SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"
cp "$SSH_CONFIG" "${SSH_CONFIG}${BACKUP_SUFFIX}"
info "Backup saved: ${SSH_CONFIG}${BACKUP_SUFFIX}"

# Marker comments so re-runs can replace the managed block
START_MARKER="# >>> MANAGED BY ssh_key_rotate.sh — DO NOT EDIT MANUALLY >>>"
END_MARKER="# <<< END MANAGED BLOCK <<<"

# Remove old managed block if present
if grep -qF "$START_MARKER" "$SSH_CONFIG"; then
    sed -i "/$START_MARKER/,/$END_MARKER/d" "$SSH_CONFIG"
fi

{
    echo ""
    echo "$START_MARKER"
    for host in "${SUCCESS[@]}"; do
        alias="${ALIASES[$host]}"
        user="${USERS[$host]}"
        key_name="id_${KEY_TYPE}_${alias}"
        key_path="${KEY_DIR}/${key_name}"
        cat <<EOF

Host ${alias}
    HostName ${host}
    User ${user}
    IdentityFile ${key_path}
    IdentitiesOnly yes
EOF
    done
    echo ""
    echo "$END_MARKER"
} >> "$SSH_CONFIG"

info "SSH config updated. You can now connect with: ssh <alias>"

# --- Summary ------------------------------------------------------------------
echo ""
echo "========================================="
echo "  SUMMARY"
echo "========================================="
info "Succeeded: ${#SUCCESS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    warn "Failed:    ${#FAILED[@]}"
    for h in "${FAILED[@]}"; do
        echo "    - $h"
    done
fi
echo ""
info "Keys stored in:  $KEY_DIR/"
info "SSH config:      $SSH_CONFIG"
echo ""
info "Test with:  ssh <alias>    (e.g., ssh ${ALIASES[${HOSTS[0]}]})"
