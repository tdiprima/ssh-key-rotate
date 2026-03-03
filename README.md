# ssh-key-rotate

Tired of sharing one SSH key across every server? This script fixes that.

It generates a unique key per server, deploys the new keys, revokes the old shared key, and wires everything up in `~/.ssh/config` so you can just type `ssh webserver` and be done with it.

## What it does

1. Reads your server list from `servers.txt`
2. Generates a fresh SSH key for each server (ed25519 by default)
3. Deploys the new public key to the remote `~/.ssh/authorized_keys`
4. Revokes the old shared key from each server
5. Updates `~/.ssh/config` with a tidy `Host` block per server
6. Shows a summary of what succeeded and what didn't

## Setup

**1. Edit `servers.txt`** — one server per line:

```
IP_OR_HOSTNAME      [optional_alias]  [optional_user]
192.168.1.10        webserver         deploy
10.0.0.5            dbserver
myhost.example.com
```

- `alias` — friendly name used in `~/.ssh/config` and the key filename (defaults to the hostname)
- `user` — SSH user for that server (defaults to the `SSH_USER` env var, or `root`)

**2. Set your old key** (the one you want to revoke):

```bash
export OLD_PUB_KEY=~/.ssh/id_rsa.pub   # default; change if needed
```

**3. Run it:**

```bash
./ssh_key_rotate.sh
```

The script will show you the plan and ask for confirmation before touching anything.

## After it runs

Connect using the alias you defined:

```bash
ssh webserver
ssh dbserver
```

New keys are stored in `~/.ssh/per-server/`. The script backs up your `~/.ssh/config` before modifying it.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `OLD_PUB_KEY` | `~/.ssh/id_rsa.pub` | Public key to revoke |
| `SSH_USER` | `root` | Default SSH user |
| `KEY_TYPE` | `ed25519` | Key type (`ed25519` or `rsa`) |
| `RSA_BITS` | `4096` | Bit size (RSA only) |
| `KEY_DIR` | `~/.ssh/per-server` | Where new keys are stored |
| `SERVERS_FILE` | `./servers.txt` | Path to your server list |

## ⚠️ Disclaimer

This script performs SSH authentication changes across remote systems. It modifies `authorized_keys` files on servers you point it at, revokes existing keys, and rewrites your local `~/.ssh/config`.

**Use it only on systems you own or have explicit authorization to manage.**

Test in a safe environment before running against production. The author is not responsible for locked-out servers, lost access, disrupted services, or any other consequences arising from the use of this script. You run it at your own risk.

Back up your keys and configs before you start. The script creates a timestamped backup of `~/.ssh/config`, but ultimately **you** are responsible for your infrastructure.

<br>
