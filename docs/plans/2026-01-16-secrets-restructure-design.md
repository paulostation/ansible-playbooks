# Secrets Management Restructure Design

## Problem

The current `hosts.sops.yml` file combines all inventory and secrets into a single encrypted file. SOPS re-encrypts all values with new IVs on every edit, causing:

- **Unreadable diffs**: 170+ line changes for adding one variable
- **Polluted git history**: `git blame` and history exploration useless
- **Merge conflicts**: Any parallel changes conflict

## Solution

Split into per-host and per-group files using Ansible's standard `host_vars/` and `group_vars/` directories.

## New Structure

```
ansible-playbooks/
├── hosts.yml                          # Plain inventory (unencrypted)
├── .sops.yaml                         # Updated creation rules
│
├── group_vars/
│   ├── home/
│   │   └── secrets.sops.yml           # atuin_*, chezmoi_*, ansible_ssh_common_args
│   └── aws_vpn_hub/
│       └── secrets.sops.yml           # wireguard pubkeys for all peers
│
├── host_vars/
│   ├── localhost/
│   │   └── secrets.sops.yml
│   ├── asus-tuf/
│   │   └── secrets.sops.yml
│   ├── stremio-rpi/
│   │   ├── secrets.sops.yml
│   │   └── argocd.sops.yml            # already exists
│   ├── vpn-hub/
│   │   └── secrets.sops.yml
│   └── ... (one dir per host)
```

## Plain `hosts.yml` Inventory

Contains only structure and non-sensitive info:

```yaml
all:
  children:
    aws_vpn_hub:
      hosts:
        vpn-hub:                        # alias, actual IP in host_vars

    local:
      hosts:
        localhost:
          ansible_connection: local

    home:
      hosts:
        192.168.15.3:
        192.168.15.6:
        prod-primaria:
        asus-tuf:
        granado-linux-mtz:
        thinkpad-DEV:
        thinkpad-DEV02:
        prod-FTZ:
        prod-SPO:
        approve-prod-sa-east-1:
        kali-mouse:
        mouse:
        omarchy-pc-do-b:
        stremio-rpi:
        raspberry-pi-home:
        raspberry-pi-bravo-vpn:
```

Privacy level: Internal IPs visible, public IPs and credentials encrypted.

## Group Variables

### `group_vars/home/secrets.sops.yml`

Shared by all hosts in `home` group:

- `ansible_ssh_common_args`
- `chezmoi_github_username`
- `atuin_username`
- `atuin_password`
- `atuin_email`
- `atuin_key`

### `group_vars/aws_vpn_hub/secrets.sops.yml`

VPN peer public keys (hub needs all peer pubkeys):

- `desktop_wireguard_pubkey`
- `rpi_wireguard_pubkey`
- `phone_wireguard_pubkey`
- `asus_tuf_wireguard_pubkey`
- `omarchy_pc_do_b_wireguard_pubkey`

## Host Variables

Each host gets only its specific secrets:

- `ansible_user`
- `ansible_host` (for hosts using aliases)
- `ansible_become_pass` (where applicable)
- `wireguard_client_ip`
- `asdf_user`, `asdf_shell`, `asdf_plugins`
- Host-specific configs (wifi, docker, devices, etc.)

## Updated `.sops.yaml`

```yaml
creation_rules:
  - path_regex: .*(host_vars|group_vars)/.*\.sops\.(yml|yaml)$
    age: age18y8alr4hmg0cupmqwlzjgrmwn495q74275jfk4j4hyvlgv80n3vsc8th8g
    kms: arn:aws:kms:us-east-1:256935246980:key/e066688f-aa55-470e-9a33-84393e9c4310

  - path_regex: .*\.sops\.(yml|yaml)$
    age: age18y8alr4hmg0cupmqwlzjgrmwn495q74275jfk4j4hyvlgv80n3vsc8th8g
    kms: arn:aws:kms:us-east-1:256935246980:key/e066688f-aa55-470e-9a33-84393e9c4310
```

## Migration Steps

1. Decrypt current `hosts.sops.yml` to plaintext (working copy)
2. Create `hosts.yml` with inventory structure
3. Create `group_vars/home/secrets.sops.yml` with shared vars
4. Create `group_vars/aws_vpn_hub/secrets.sops.yml` with peer pubkeys
5. Create `host_vars/<host>/secrets.sops.yml` for each host
6. Test with `ansible-inventory --list` to verify vars merge correctly
7. Run a playbook against one host to validate
8. Delete old `hosts.sops.yml`
9. Commit all changes

## Benefits

| Before | After |
|--------|-------|
| 170+ line diffs for small changes | 10-30 line diffs per host file |
| All hosts in one file | Isolated files per host |
| Merge conflicts on any parallel edit | Conflicts only if same host edited |
| `git blame` useless | Clear history per host |

## Risks & Mitigations

- **Playbook references**: Search for direct `hosts.sops.yml` references and update
- **Ansible inventory path**: Ensure `ansible.cfg` or `-i` flag points to `hosts.yml`
- **Variable precedence**: `host_vars` overrides `group_vars` - this is desired behavior
