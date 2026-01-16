# Secrets Restructure Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split monolithic `hosts.sops.yml` into per-host and per-group files to improve diff readability and reduce merge conflicts.

**Architecture:** Create plain `hosts.yml` for inventory structure, `group_vars/` for shared secrets, `host_vars/` for per-host secrets. SOPS encrypts each small file independently.

**Tech Stack:** Ansible, SOPS, age encryption, AWS KMS

---

## Pre-flight

**Working directory:** `/home/paulao/Source_Codes/ansible-playbooks/.worktrees/secrets-restructure`

**Verify SOPS access before starting:**
```bash
sops -d hosts.sops.yml > /dev/null && echo "SOPS OK"
```

---

### Task 1: Decrypt Current Inventory

**Files:**
- Read: `hosts.sops.yml`
- Create: `/tmp/hosts-decrypted.yml` (temporary working copy)

**Step 1: Decrypt to temp file**

```bash
sops -d hosts.sops.yml > /tmp/hosts-decrypted.yml
```

**Step 2: Verify decryption**

```bash
head -20 /tmp/hosts-decrypted.yml
```

Expected: Plain YAML without `ENC[AES256_GCM,...]` markers

**Step 3: No commit** (temp file only)

---

### Task 2: Create Plain hosts.yml

**Files:**
- Create: `hosts.yml`

**Step 1: Create inventory structure**

```yaml
all:
  children:
    aws_vpn_hub:
      hosts:
        vpn-hub:
          # ansible_host defined in host_vars/vpn-hub/secrets.sops.yml

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

**Step 2: Verify syntax**

```bash
ansible-inventory -i hosts.yml --list > /dev/null && echo "SYNTAX OK"
```

Expected: No errors (vars will be empty, that's fine)

**Step 3: Commit**

```bash
git add hosts.yml
git commit -m "feat: add plain inventory structure

Inventory structure without secrets. Host and group vars
will be loaded from host_vars/ and group_vars/ directories."
```

---

### Task 3: Create group_vars/home/secrets.sops.yml

**Files:**
- Create: `group_vars/home/secrets.sops.yml`

**Step 1: Create directory and file**

Extract these values from `/tmp/hosts-decrypted.yml` under `all.children.home.vars`:

```bash
mkdir -p group_vars/home
```

Create `group_vars/home/secrets.sops.yml` with:

```yaml
ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
chezmoi_github_username: <value from decrypted file>
atuin_username: <value from decrypted file>
atuin_password: <value from decrypted file>
atuin_email: <value from decrypted file>
atuin_key: <value from decrypted file>
```

**Step 2: Encrypt the file**

```bash
sops -e -i group_vars/home/secrets.sops.yml
```

**Step 3: Verify encryption**

```bash
head -5 group_vars/home/secrets.sops.yml | grep -q "ENC\[AES256" && echo "ENCRYPTED"
```

**Step 4: Verify decryption works**

```bash
sops -d group_vars/home/secrets.sops.yml | head -3
```

**Step 5: Commit**

```bash
git add group_vars/home/secrets.sops.yml
git commit -m "feat: add home group shared secrets

Shared vars for all hosts in home group:
- ansible_ssh_common_args
- chezmoi/atuin credentials"
```

---

### Task 4: Create group_vars/aws_vpn_hub/secrets.sops.yml

**Files:**
- Create: `group_vars/aws_vpn_hub/secrets.sops.yml`

**Step 1: Create directory and file**

Extract peer pubkeys from `/tmp/hosts-decrypted.yml` under `all.children.aws_vpn_hub.hosts.98.88.176.1`:

```bash
mkdir -p group_vars/aws_vpn_hub
```

Create `group_vars/aws_vpn_hub/secrets.sops.yml` with:

```yaml
desktop_wireguard_pubkey: <value from decrypted file>
rpi_wireguard_pubkey: <value from decrypted file>
phone_wireguard_pubkey: <value from decrypted file>
asus_tuf_wireguard_pubkey: <value from decrypted file>
omarchy_pc_do_b_wireguard_pubkey: <value from decrypted file>
```

**Step 2: Encrypt the file**

```bash
sops -e -i group_vars/aws_vpn_hub/secrets.sops.yml
```

**Step 3: Verify encryption and decryption**

```bash
sops -d group_vars/aws_vpn_hub/secrets.sops.yml | head -3
```

**Step 4: Commit**

```bash
git add group_vars/aws_vpn_hub/secrets.sops.yml
git commit -m "feat: add VPN hub peer public keys

All WireGuard peer pubkeys for the VPN hub to configure peers."
```

---

### Task 5: Create host_vars for VPN hub

**Files:**
- Create: `host_vars/vpn-hub/secrets.sops.yml`

**Step 1: Create directory and file**

Extract from `/tmp/hosts-decrypted.yml` under `all.children.aws_vpn_hub.hosts.98.88.176.1`:

```bash
mkdir -p host_vars/vpn-hub
```

Create `host_vars/vpn-hub/secrets.sops.yml` with:

```yaml
ansible_host: "98.88.176.1"
ansible_user: <value from decrypted file>
ansible_python_interpreter: <value from decrypted file>
```

**Step 2: Encrypt and verify**

```bash
sops -e -i host_vars/vpn-hub/secrets.sops.yml
sops -d host_vars/vpn-hub/secrets.sops.yml | head -3
```

**Step 3: Commit**

```bash
git add host_vars/vpn-hub/secrets.sops.yml
git commit -m "feat: add vpn-hub host vars"
```

---

### Task 6: Create host_vars for localhost

**Files:**
- Create: `host_vars/localhost/secrets.sops.yml`

**Step 1: Create directory and file**

Extract from `/tmp/hosts-decrypted.yml` under `all.children.local.hosts.localhost`:

```bash
mkdir -p host_vars/localhost
```

Create `host_vars/localhost/secrets.sops.yml` with all localhost-specific vars (ansible_user, ansible_become_pass, asdf_user, asdf_shell, asdf_plugins).

**Step 2: Encrypt and verify**

```bash
sops -e -i host_vars/localhost/secrets.sops.yml
sops -d host_vars/localhost/secrets.sops.yml | head -5
```

**Step 3: Commit**

```bash
git add host_vars/localhost/secrets.sops.yml
git commit -m "feat: add localhost host vars"
```

---

### Task 7: Create host_vars for remaining hosts

**Files:**
- Create: `host_vars/<hostname>/secrets.sops.yml` for each host

**Hosts to process (from home group):**
1. `192.168.15.3`
2. `192.168.15.6`
3. `prod-primaria`
4. `asus-tuf`
5. `granado-linux-mtz`
6. `thinkpad-DEV`
7. `thinkpad-DEV02`
8. `prod-FTZ`
9. `prod-SPO`
10. `approve-prod-sa-east-1`
11. `kali-mouse`
12. `mouse`
13. `omarchy-pc-do-b`
14. `stremio-rpi`
15. `raspberry-pi-home`
16. `raspberry-pi-bravo-vpn`

**For each host:**

1. Create directory: `mkdir -p host_vars/<hostname>`
2. Extract host-specific vars from `/tmp/hosts-decrypted.yml`
3. Create `host_vars/<hostname>/secrets.sops.yml` with those vars
4. Encrypt: `sops -e -i host_vars/<hostname>/secrets.sops.yml`
5. Verify: `sops -d host_vars/<hostname>/secrets.sops.yml | head -3`

**Commit after each host or batch:**

```bash
git add host_vars/
git commit -m "feat: add host_vars for remaining hosts

Created encrypted secrets files for all hosts in home group."
```

---

### Task 8: Update .sops.yaml

**Files:**
- Modify: `.sops.yaml`

**Step 1: Update creation rules**

```yaml
# SOPS configuration file
# Uses both age and AWS KMS encryption for redundancy

creation_rules:
  # Match any .sops.yml file in host_vars or group_vars
  - path_regex: .*(host_vars|group_vars)/.*\.sops\.(yml|yaml)$
    age: age18y8alr4hmg0cupmqwlzjgrmwn495q74275jfk4j4hyvlgv80n3vsc8th8g
    kms: arn:aws:kms:us-east-1:256935246980:key/e066688f-aa55-470e-9a33-84393e9c4310

  # Match any .sops.yml or .sops.yaml file (fallback)
  - path_regex: .*\.sops\.(yml|yaml)$
    age: age18y8alr4hmg0cupmqwlzjgrmwn495q74275jfk4j4hyvlgv80n3vsc8th8g
    kms: arn:aws:kms:us-east-1:256935246980:key/e066688f-aa55-470e-9a33-84393e9c4310
```

**Step 2: Commit**

```bash
git add .sops.yaml
git commit -m "chore: update sops config for host_vars/group_vars"
```

---

### Task 9: Validate with ansible-inventory

**Step 1: Test inventory loads correctly**

```bash
ansible-inventory -i hosts.yml --list | head -50
```

Expected: JSON output showing hosts with their vars merged from host_vars/group_vars

**Step 2: Verify specific host vars**

```bash
ansible-inventory -i hosts.yml --host asus-tuf
```

Expected: All vars for asus-tuf including group_vars from `home`

**Step 3: Verify group vars inheritance**

```bash
ansible-inventory -i hosts.yml --host stremio-rpi | grep atuin
```

Expected: Should show atuin_* vars from group_vars/home

**Step 4: No commit** (validation only)

---

### Task 10: Remove old hosts.sops.yml

**Files:**
- Delete: `hosts.sops.yml`

**Step 1: Final validation before deletion**

```bash
# Test a quick ansible ping (adjust host as needed)
ansible -i hosts.yml localhost -m ping
```

**Step 2: Remove old file**

```bash
git rm hosts.sops.yml
```

**Step 3: Clean up temp file**

```bash
rm /tmp/hosts-decrypted.yml
```

**Step 4: Final commit**

```bash
git commit -m "chore: remove monolithic hosts.sops.yml

Secrets now split into:
- group_vars/home/secrets.sops.yml
- group_vars/aws_vpn_hub/secrets.sops.yml
- host_vars/<hostname>/secrets.sops.yml

Benefits:
- Smaller diffs when editing one host
- Reduced merge conflicts
- Cleaner git history per host"
```

---

### Task 11: Update .gitignore

**Files:**
- Modify: `.gitignore`

**Step 1: Remove hosts.yml from gitignore**

The current `.gitignore` has `hosts.yml` ignored (it was meant to prevent committing decrypted files). Now we want the plain inventory committed.

Remove or comment out:
```
# Unencrypted inventory (use hosts.sops.yml instead)
hosts.yml
```

**Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: allow hosts.yml in git

Plain inventory structure is now committed.
Secrets are in host_vars/ and group_vars/."
```

---

## Post-Implementation Checklist

- [ ] All hosts have corresponding host_vars directory
- [ ] group_vars/home has shared secrets
- [ ] group_vars/aws_vpn_hub has peer pubkeys
- [ ] `ansible-inventory --list` shows all vars correctly
- [ ] `ansible localhost -m ping` works
- [ ] Old hosts.sops.yml is deleted
- [ ] All sops files decrypt successfully
