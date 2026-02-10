# SSH Key Rotate
Because you should have 1 key for each server.

Usage guide for `ssh_key_rotate.sh`:

## What It Does

- Generates a new per-server SSH key.
- Deploys the new public key to each server.
- Revokes the old shared key from each server.
- Updates `~/.ssh/config` with per-server aliases and identity files.

## Prerequisites

- SSH access to each server using the old key.
- `servers.txt` listing targets (one per line):

```text
IP_OR_HOSTNAME  [optional_alias]  [optional_user]
192.168.1.10    webserver         deploy
10.0.0.5        dbserver
myhost.example.com
```

## Configuration

Defaults can be overridden with environment variables:

- `OLD_PUB_KEY` (default: `~/.ssh/id_rsa.pub`)
- `SSH_USER` (default: `root`)
- `KEY_TYPE` (default: `ed25519`; use `rsa` for legacy)
- `RSA_BITS` (default: `4096` if `KEY_TYPE=rsa`)
- `KEY_DIR` (default: `~/.ssh/per-server`)
- `SERVERS_FILE` (default: `./servers.txt`)

## Run

⚠️ Always keep an existing SSH session open while testing new keys. ⚠️

```bash
./ssh_key_rotate.sh
```

Example with overrides:

```bash
OLD_PUB_KEY=~/.ssh/old_shared.pub SSH_USER=deploy KEY_TYPE=ed25519 ./ssh_key_rotate.sh
```

## Output

- Keys are written to `KEY_DIR` (one keypair per server alias).
- `~/.ssh/config` is updated with a managed block and a timestamped backup.
- Successful hosts are added to SSH config. Failed hosts are listed in the summary.

## Connect Afterward

Use the alias from `servers.txt`:

```bash
ssh <alias>
```

## ⚠️ Important Notice

This script performs **SSH authentication changes** across remote systems, including:

* Generating new private/public key pairs
* Deploying new keys to servers
* **Removing an existing authorized key**
* Modifying the local `~/.ssh/config`

While safety checks and confirmations are included, incorrect usage or environmental differences can result in **loss of SSH access**, service disruption, or broken automation.

**You are responsible for:**

* Ensuring you have alternate access (console, cloud provider console, etc.)
* Verifying connectivity before rotating keys in production
* Safely storing generated private keys
* Testing in non-production environments first

Use at your own risk. The author is not liable for:

* Loss of access to servers
* Downtime or operational impact
* Security issues resulting from improper key handling
* Etc.
