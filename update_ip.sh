#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# One-off script: update SSH config for "grace" after IP change
# Old IP: <IP_ADDRESS>  ->  New IP: <IP_ADDRESS>
# Key already exists at ~/.ssh/per-server/id_ed25519_NAME
# =============================================================================

OLD_IP="IP_ADDRESS"
NEW_IP="IP_ADDRESS"
ALT_IP="IP_ADDRESS"   # secondary IP — set DEPLOY_ALT=true to also push key there
HOST_ALIAS="HOST"
SSH_USER="USER"
KEY_PATH="$HOME/.ssh/per-server/id_ed25519_NAME"
SSH_CONFIG="$HOME/.ssh/config"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
DEPLOY_ALT="${DEPLOY_ALT:-false}"  # set to true if you also want the key on .198

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Preflight ----------------------------------------------------------------
if [[ ! -f "$KEY_PATH" ]]; then
    err "Key not found: $KEY_PATH"
    exit 1
fi
if [[ ! -f "${KEY_PATH}.pub" ]]; then
    err "Public key not found: ${KEY_PATH}.pub"
    exit 1
fi

NEW_PUB="$(cat "${KEY_PATH}.pub")"

echo ""
echo "Plan:"
echo "  1. Remove old IP ($OLD_IP) from known_hosts"
echo "  2. Update ~/.ssh/config: $HOST_ALIAS -> $NEW_IP"
echo "  3. Deploy existing public key to $NEW_IP"
[[ "$DEPLOY_ALT" == "true" ]] && echo "  4. Also deploy key to $ALT_IP"
echo ""
read -rp "Proceed? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
echo ""

# --- 1. Clean known_hosts -----------------------------------------------------
info "Removing old known_hosts entries for $OLD_IP..."
if grep -q "$OLD_IP" "$KNOWN_HOSTS" 2>/dev/null; then
    ssh-keygen -R "$OLD_IP" -f "$KNOWN_HOSTS" 2>/dev/null
    info "Removed $OLD_IP from known_hosts."
else
    info "$OLD_IP not found in known_hosts (already clean)."
fi

# Also remove the alias if it points to the old IP
if grep -q "^$HOST_ALIAS" "$KNOWN_HOSTS" 2>/dev/null; then
    ssh-keygen -R "$HOST_ALIAS" -f "$KNOWN_HOSTS" 2>/dev/null
    info "Removed '$HOST_ALIAS' entry from known_hosts."
fi

# --- 2. Update ~/.ssh/config --------------------------------------------------
info "Updating ~/.ssh/config..."
BACKUP="${SSH_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SSH_CONFIG" "$BACKUP"
info "Backup saved: $BACKUP"

# Replace the HostName line inside the grace block
# Uses awk to only change HostName within the matching Host block
awk -v alias="$HOST_ALIAS" -v new_ip="$NEW_IP" '
    /^Host[[:space:]]+/ { in_block = ($2 == alias) }
    in_block && /^[[:space:]]*HostName[[:space:]]+/ { sub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, new_ip) }
    { print }
' "$BACKUP" > "$SSH_CONFIG"

info "~/.ssh/config updated: $HOST_ALIAS now points to $NEW_IP"

# Verify the change
echo ""
echo "--- Resulting config block for '$HOST_ALIAS' ---"
awk "/^Host[[:space:]]+$HOST_ALIAS/{found=1} found{print; if(/^$/ && found>1) exit; found++}" "$SSH_CONFIG" | head -10
echo "---"
echo ""

# --- 3. Deploy existing public key to new IP ----------------------------------
deploy_key() {
    local target_ip="$1"
    info "Deploying public key to ${SSH_USER}@${target_ip}..."

    REMOTE_SCRIPT=$(cat <<'REMOTE_EOF'
set -e
AUTH_FILE="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"
touch "$AUTH_FILE"
chmod 700 "$HOME/.ssh"
chmod 600 "$AUTH_FILE"
if ! grep -qF "$NEW_PUB" "$AUTH_FILE" 2>/dev/null; then
    echo "$NEW_PUB" >> "$AUTH_FILE"
    echo "  [remote] Key added."
else
    echo "  [remote] Key already present."
fi
REMOTE_EOF
    )

    if ssh -o ConnectTimeout=10 \
           -o StrictHostKeyChecking=accept-new \
           "${SSH_USER}@${target_ip}" \
           "NEW_PUB=$(printf '%q' "$NEW_PUB") bash -s" \
           <<< "$REMOTE_SCRIPT"; then
        info "Key deployed to $target_ip."

        info "Verifying key login..."
        if ssh -o ConnectTimeout=10 \
               -o BatchMode=yes \
               -i "$KEY_PATH" \
               "${SSH_USER}@${target_ip}" "echo '  [remote] Key works!'"; then
            info "✓ Login with new key verified on $target_ip."
        else
            warn "Key verification failed on $target_ip — check manually."
        fi
    else
        err "Could not connect to $target_ip. Is it reachable?"
    fi
}

deploy_key "$NEW_IP"

if [[ "$DEPLOY_ALT" == "true" ]]; then
    echo ""
    deploy_key "$ALT_IP"
fi

# --- Done ---------------------------------------------------------------------
echo ""
echo "========================================="
echo "  DONE"
echo "========================================="
info "Connect with:  ssh $HOST_ALIAS"
info "Or directly:   ssh -i $KEY_PATH ${SSH_USER}@${NEW_IP}"
echo ""
