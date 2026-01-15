# PR #31 Breakdown Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Break down the large PR #31 (feat/yazi) into 6 smaller, semantic PRs that can be reviewed and merged incrementally.

**Architecture:** Each PR will be created from a fresh branch off origin/main, cherry-picking only the relevant files for that topic. This ensures clean, conflict-free PRs that can be merged in any order.

**Tech Stack:** Git, Ansible, WireGuard, k3s, ArgoCD

**Source Branch:** `origin/feat/yazi`
**Target Branch:** `origin/main`

**Note:** PR #32 already handles hosts.yml/hosts.sops.yml/.sops.yaml reconciliation - those files are excluded from this plan.

---

## PR Dependencies

```
PR #32 (hosts reconciliation) - MERGED or ready to merge first
    │
    ├── PR A: VPN Infrastructure (no deps)
    ├── PR B: Kubernetes/ArgoCD (no deps)
    ├── PR C: Stremio RPi (depends on B for k3s/argocd roles)
    ├── PR D: PXE Server (no deps)
    ├── PR E: Dev Utils Cleanup (no deps)
    └── PR F: Misc Improvements (no deps)
```

---

## Task 1: VPN Infrastructure

**Branch:** `feat/vpn-infrastructure`

**Files to add:**
- `playbooks/vpn-hub.yml`
- `roles/wireguard_server/defaults/main.yml`
- `roles/wireguard_server/handlers/main.yml`
- `roles/wireguard_server/tasks/main.yml`
- `roles/wireguard_server/templates/wg0.conf.j2`
- `roles/wireguard_client/defaults/main.yml`
- `roles/wireguard_client/handlers/main.yml`
- `roles/wireguard_client/tasks/main.yml`
- `roles/wireguard_client/templates/wg0.conf.j2`
- `roles/oci_dnsmasq/defaults/main.yml`
- `roles/oci_dnsmasq/handlers/main.yml`
- `roles/oci_dnsmasq/tasks/main.yml`
- `roles/oci_dnsmasq/templates/dnsmasq.conf.j2`
- `roles/oci_dnsmasq/templates/hosts.local.j2`

**Files to modify:**
- `Makefile` (add vpn-hub target)

**Step 1: Create worktree and branch**

```bash
cd /home/paulao/Source_Codes/ansible-playbooks
git fetch origin
# Worktree already exists at .worktrees/vpn-infra
cd .worktrees/vpn-infra
git reset --hard origin/main
```

**Step 2: Copy VPN roles from feat/yazi**

```bash
# Copy wireguard_server role
mkdir -p roles/wireguard_server/{defaults,handlers,tasks,templates}
git show origin/feat/yazi:roles/wireguard_server/defaults/main.yml > roles/wireguard_server/defaults/main.yml
git show origin/feat/yazi:roles/wireguard_server/handlers/main.yml > roles/wireguard_server/handlers/main.yml
git show origin/feat/yazi:roles/wireguard_server/tasks/main.yml > roles/wireguard_server/tasks/main.yml
git show origin/feat/yazi:roles/wireguard_server/templates/wg0.conf.j2 > roles/wireguard_server/templates/wg0.conf.j2

# Copy wireguard_client role
mkdir -p roles/wireguard_client/{defaults,handlers,tasks,templates}
git show origin/feat/yazi:roles/wireguard_client/defaults/main.yml > roles/wireguard_client/defaults/main.yml
git show origin/feat/yazi:roles/wireguard_client/handlers/main.yml > roles/wireguard_client/handlers/main.yml
git show origin/feat/yazi:roles/wireguard_client/tasks/main.yml > roles/wireguard_client/tasks/main.yml
git show origin/feat/yazi:roles/wireguard_client/templates/wg0.conf.j2 > roles/wireguard_client/templates/wg0.conf.j2

# Copy oci_dnsmasq role
mkdir -p roles/oci_dnsmasq/{defaults,handlers,tasks,templates}
git show origin/feat/yazi:roles/oci_dnsmasq/defaults/main.yml > roles/oci_dnsmasq/defaults/main.yml
git show origin/feat/yazi:roles/oci_dnsmasq/handlers/main.yml > roles/oci_dnsmasq/handlers/main.yml
git show origin/feat/yazi:roles/oci_dnsmasq/tasks/main.yml > roles/oci_dnsmasq/tasks/main.yml
git show origin/feat/yazi:roles/oci_dnsmasq/templates/dnsmasq.conf.j2 > roles/oci_dnsmasq/templates/dnsmasq.conf.j2
git show origin/feat/yazi:roles/oci_dnsmasq/templates/hosts.local.j2 > roles/oci_dnsmasq/templates/hosts.local.j2

# Copy vpn-hub playbook
git show origin/feat/yazi:playbooks/vpn-hub.yml > playbooks/vpn-hub.yml
```

**Step 3: Update Makefile with vpn-hub target**

Add to Makefile after oci-homelab target:
```makefile
vpn-hub:
	$(setup_env)
	$(decrypt_inventory)
	@trap '$(cleanup_inventory)' EXIT; \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/vpn-hub.yml $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)
```

Also update .PHONY and help sections.

**Step 4: Verify syntax**

```bash
source .venv/bin/activate
ansible-playbook --syntax-check playbooks/vpn-hub.yml
```

**Step 5: Commit and push**

```bash
git add roles/wireguard_server roles/wireguard_client roles/oci_dnsmasq playbooks/vpn-hub.yml Makefile
git commit -m "feat(vpn): add WireGuard VPN hub roles and playbook

- Add wireguard_server role for VPN hub configuration
- Add wireguard_client role for VPN peer configuration
- Add oci_dnsmasq role for DNS resolution over VPN
- Add vpn-hub.yml playbook targeting aws_vpn_hub group
- Add make vpn-hub target

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

git push -u origin feat/vpn-infrastructure
```

**Step 6: Create PR**

```bash
gh pr create --base main --title "feat(vpn): add WireGuard VPN hub roles and playbook" --body "## Summary
- Add wireguard_server role for VPN hub configuration
- Add wireguard_client role for VPN peer configuration
- Add oci_dnsmasq role for DNS resolution over VPN
- Add vpn-hub.yml playbook targeting aws_vpn_hub group

## Roles Added
- \`wireguard_server\`: Configures WireGuard server with peer management
- \`wireguard_client\`: Configures WireGuard client to connect to VPN hub
- \`oci_dnsmasq\`: DNS server for resolving internal hostnames over VPN

## Test plan
- [ ] Run \`make vpn-hub ARGS='--check'\` to verify playbook syntax
- [ ] Verify roles have correct defaults and templates

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Task 2: Kubernetes/ArgoCD

**Branch:** `feat/k3s-argocd`

**Files to add:**
- `roles/k3s/defaults/main.yml`
- `roles/k3s/handlers/main.yml`
- `roles/k3s/tasks/main.yml`
- `roles/argocd/defaults/main.yml`
- `roles/argocd/tasks/main.yml`
- `roles/argocd/templates/argocd-values.yaml.j2`
- `roles/argocd/templates/root-app.yaml.j2`
- `host_vars/stremio-rpi/argocd.yml`

**Step 1: Create worktree and branch**

```bash
git worktree add .worktrees/k3s-argocd -b feat/k3s-argocd origin/main
cd .worktrees/k3s-argocd
```

**Step 2: Copy k3s and argocd roles**

```bash
# Copy k3s role
mkdir -p roles/k3s/{defaults,handlers,tasks}
git show origin/feat/yazi:roles/k3s/defaults/main.yml > roles/k3s/defaults/main.yml
git show origin/feat/yazi:roles/k3s/handlers/main.yml > roles/k3s/handlers/main.yml
git show origin/feat/yazi:roles/k3s/tasks/main.yml > roles/k3s/tasks/main.yml

# Copy argocd role
mkdir -p roles/argocd/{defaults,tasks,templates}
git show origin/feat/yazi:roles/argocd/defaults/main.yml > roles/argocd/defaults/main.yml
git show origin/feat/yazi:roles/argocd/tasks/main.yml > roles/argocd/tasks/main.yml
git show origin/feat/yazi:roles/argocd/templates/argocd-values.yaml.j2 > roles/argocd/templates/argocd-values.yaml.j2
git show origin/feat/yazi:roles/argocd/templates/root-app.yaml.j2 > roles/argocd/templates/root-app.yaml.j2

# Copy host_vars
mkdir -p host_vars/stremio-rpi
git show origin/feat/yazi:host_vars/stremio-rpi/argocd.yml > host_vars/stremio-rpi/argocd.yml
```

**Step 3: Commit and push**

```bash
git add roles/k3s roles/argocd host_vars/stremio-rpi
git commit -m "feat(k8s): add k3s and ArgoCD roles

- Add k3s role for lightweight Kubernetes installation
- Add argocd role for GitOps deployment with KSOPS support
- Add host_vars for stremio-rpi ArgoCD configuration

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

git push -u origin feat/k3s-argocd
```

**Step 4: Create PR**

```bash
gh pr create --base main --title "feat(k8s): add k3s and ArgoCD roles" --body "## Summary
- Add k3s role for lightweight Kubernetes installation
- Add ArgoCD role for GitOps deployment with KSOPS support

## Roles Added
- \`k3s\`: Installs k3s with secrets encryption at rest
- \`argocd\`: Deploys ArgoCD via Helm with KSOPS for secret decryption

## Test plan
- [ ] Verify role syntax with ansible-lint
- [ ] Check templates render correctly

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Task 3: Stremio RPi

**Branch:** `feat/stremio-rpi`

**Dependencies:** Task 2 (k3s/argocd roles) should be merged first

**Files to add:**
- `playbooks/stremio-rpi.yml`
- `playbooks/oci-homelab.yml`

**Files to modify:**
- `roles/networking/defaults/main.yml`
- `roles/networking/tasks/main.yml`
- `roles/networking/templates/netplancfg.j2`

**Step 1: Create worktree and branch**

```bash
git worktree add .worktrees/stremio-rpi -b feat/stremio-rpi origin/main
cd .worktrees/stremio-rpi
```

**Step 2: Copy playbooks**

```bash
git show origin/feat/yazi:playbooks/stremio-rpi.yml > playbooks/stremio-rpi.yml
git show origin/feat/yazi:playbooks/oci-homelab.yml > playbooks/oci-homelab.yml
```

**Step 3: Copy networking role changes**

```bash
git show origin/feat/yazi:roles/networking/defaults/main.yml > roles/networking/defaults/main.yml
git show origin/feat/yazi:roles/networking/tasks/main.yml > roles/networking/tasks/main.yml
git show origin/feat/yazi:roles/networking/templates/netplancfg.j2 > roles/networking/templates/netplancfg.j2
```

**Step 4: Commit and push**

```bash
git add playbooks/stremio-rpi.yml playbooks/oci-homelab.yml roles/networking
git commit -m "feat(rpi): add Stremio RPi and OCI homelab playbooks

- Add stremio-rpi.yml for Raspberry Pi 5 with k3s and ArgoCD
- Add oci-homelab.yml for OCI VPN hub configuration
- Update networking role for WiFi and static IP support

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

git push -u origin feat/stremio-rpi
```

**Step 5: Create PR**

```bash
gh pr create --base main --title "feat(rpi): add Stremio RPi and OCI homelab playbooks" --body "## Summary
- Add playbook for Raspberry Pi 5 setup with k3s and ArgoCD
- Add OCI homelab playbook for VPN hub configuration
- Update networking role for WiFi and static IP support

## Prerequisites
- Requires k3s and argocd roles (PR: feat/k3s-argocd)

## Test plan
- [ ] Verify playbook syntax
- [ ] Test on Raspberry Pi 5 target

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Task 4: PXE Server

**Branch:** `feat/pxe-server-improvements`

**Files to modify:**
- `roles/pxe_server/defaults/main.yml`
- `roles/pxe_server/handlers/main.yml`
- `roles/pxe_server/tasks/main.yml`
- `roles/pxe_server/tasks/download_images.yml`
- `roles/pxe_server/tasks/extract_iso.yml`
- `roles/pxe_server/templates/dnsmasq-pxe.conf.j2`
- `roles/pxe_server/templates/pxelinux-default.j2`

**Files to add:**
- `roles/pxe_server/templates/exports.j2`
- `roles/pxe_server/templates/grub.cfg.j2`
- `playbooks/pxe_server.yml`

**Step 1: Create worktree and branch**

```bash
git worktree add .worktrees/pxe-server -b feat/pxe-server-improvements origin/main
cd .worktrees/pxe-server
```

**Step 2: Copy PXE server changes**

```bash
# Copy all pxe_server role files
for f in defaults/main.yml handlers/main.yml tasks/main.yml tasks/download_images.yml tasks/extract_iso.yml templates/dnsmasq-pxe.conf.j2 templates/pxelinux-default.j2 templates/exports.j2 templates/grub.cfg.j2; do
  mkdir -p roles/pxe_server/$(dirname $f)
  git show origin/feat/yazi:roles/pxe_server/$f > roles/pxe_server/$f
done

# Copy playbook
git show origin/feat/yazi:playbooks/pxe_server.yml > playbooks/pxe_server.yml
```

**Step 3: Commit and push**

```bash
git add roles/pxe_server playbooks/pxe_server.yml
git commit -m "feat(pxe): add UEFI and NFS boot support

- Add GRUB UEFI boot configuration
- Add NFS exports for network boot
- Improve image download and extraction
- Add pxe_server.yml playbook

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

git push -u origin feat/pxe-server-improvements
```

**Step 4: Create PR**

```bash
gh pr create --base main --title "feat(pxe): add UEFI and NFS boot support" --body "## Summary
- Add GRUB UEFI boot configuration for modern hardware
- Add NFS exports for network boot
- Improve ISO download and extraction tasks

## Test plan
- [ ] Verify UEFI boot works on target hardware
- [ ] Test NFS mount from PXE client

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Task 5: Dev Utils Cleanup

**Branch:** `feat/dev-utils-cleanup`

**Files to remove:**
- `roles/chezmoi/` (entire directory)
- `roles/claude_code/` (entire directory)
- `roles/yazi/` (entire directory)
- `roles/sops_setup/` (entire directory)
- `roles/dev.utils/tasks/atuin.yml`
- `roles/dev.utils/templates/atuin-config.toml.j2`
- `roles/dev.utils/defaults/main.yml`
- `docs/plans/2025-12-30-atuin-design.md`
- `playbooks/setup_sops.yml`

**Files to modify:**
- `roles/dev.utils/tasks/main.yml` (remove atuin include)
- `playbooks/dev_utils.yml` (remove unused roles)

**Step 1: Create worktree and branch**

```bash
git worktree add .worktrees/dev-utils-cleanup -b feat/dev-utils-cleanup origin/main
cd .worktrees/dev-utils-cleanup
```

**Step 2: Remove unused roles and files**

```bash
rm -rf roles/chezmoi roles/claude_code roles/yazi roles/sops_setup
rm -f roles/dev.utils/tasks/atuin.yml
rm -f roles/dev.utils/templates/atuin-config.toml.j2
rm -f roles/dev.utils/defaults/main.yml
rm -f docs/plans/2025-12-30-atuin-design.md
rm -f playbooks/setup_sops.yml
```

**Step 3: Update dev.utils tasks**

Copy the updated main.yml that removes atuin:
```bash
git show origin/feat/yazi:roles/dev.utils/tasks/main.yml > roles/dev.utils/tasks/main.yml
git show origin/feat/yazi:roles/dev.utils/tasks/oh-my-zsh.yml > roles/dev.utils/tasks/oh-my-zsh.yml
git show origin/feat/yazi:playbooks/dev_utils.yml > playbooks/dev_utils.yml
```

**Step 4: Commit and push**

```bash
git add -A
git commit -m "chore: remove unused dev utility roles

Remove roles that are no longer used or maintained:
- chezmoi (dotfiles management moved elsewhere)
- claude_code (installed via other means)
- yazi (not needed)
- sops_setup (SOPS configured manually)
- atuin (shell history sync not used)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

git push -u origin feat/dev-utils-cleanup
```

**Step 5: Create PR**

```bash
gh pr create --base main --title "chore: remove unused dev utility roles" --body "## Summary
Clean up roles that are no longer used or maintained.

## Removed
- \`chezmoi/\` - dotfiles management moved elsewhere
- \`claude_code/\` - installed via other means
- \`yazi/\` - file manager not needed
- \`sops_setup/\` - SOPS configured manually
- \`atuin\` tasks - shell history sync not used

## Test plan
- [ ] Verify remaining dev_utils playbook works
- [ ] Confirm no playbooks reference removed roles

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Task 6: Misc Improvements

**Branch:** `feat/misc-improvements`

**Files to modify:**
- `roles/asdf_cli/defaults/main.yml`
- `roles/asdf_cli/tasks/main.yml`
- `roles/nvim_setup/tasks/main.yml`
- `roles/syncthing/tasks/configure.yml`
- `roles/syncthing/tasks/install.yml`
- `roles/syncthing/defaults/main.yml`
- `roles/vscode/tasks/main.yml`
- `Makefile`
- `.gitignore`

**Step 1: Create worktree and branch**

```bash
git worktree add .worktrees/misc-improvements -b feat/misc-improvements origin/main
cd .worktrees/misc-improvements
```

**Step 2: Copy updated role files**

```bash
# asdf_cli
git show origin/feat/yazi:roles/asdf_cli/defaults/main.yml > roles/asdf_cli/defaults/main.yml
git show origin/feat/yazi:roles/asdf_cli/tasks/main.yml > roles/asdf_cli/tasks/main.yml

# nvim_setup
git show origin/feat/yazi:roles/nvim_setup/tasks/main.yml > roles/nvim_setup/tasks/main.yml

# syncthing
git show origin/feat/yazi:roles/syncthing/tasks/configure.yml > roles/syncthing/tasks/configure.yml
git show origin/feat/yazi:roles/syncthing/tasks/install.yml > roles/syncthing/tasks/install.yml
git show origin/feat/yazi:roles/syncthing/defaults/main.yml > roles/syncthing/defaults/main.yml

# vscode
git show origin/feat/yazi:roles/vscode/tasks/main.yml > roles/vscode/tasks/main.yml

# Makefile and gitignore
git show origin/feat/yazi:Makefile > Makefile
git show origin/feat/yazi:.gitignore > .gitignore
```

**Step 3: Commit and push**

```bash
git add roles/asdf_cli roles/nvim_setup roles/syncthing roles/vscode Makefile .gitignore
git commit -m "fix: misc improvements to asdf, nvim, syncthing, vscode roles

- Simplify asdf_cli role configuration
- Clean up nvim_setup tasks
- Fix syncthing installation and configuration
- Simplify vscode tasks
- Update Makefile with better targets
- Update .gitignore

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

git push -u origin feat/misc-improvements
```

**Step 4: Create PR**

```bash
gh pr create --base main --title "fix: misc improvements to asdf, nvim, syncthing, vscode roles" --body "## Summary
Various improvements and fixes to existing roles.

## Changes
- \`asdf_cli\`: Simplified configuration and task structure
- \`nvim_setup\`: Cleaned up installation tasks
- \`syncthing\`: Fixed installation and configuration
- \`vscode\`: Simplified extension installation
- \`Makefile\`: Better organized targets
- \`.gitignore\`: Updated patterns

## Test plan
- [ ] Run each role against a test host
- [ ] Verify no regressions

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Execution Order

Recommended merge order:

1. **PR #32** (hosts reconciliation) - Already created, merge first
2. **Task 5: Dev Utils Cleanup** - No dependencies, reduces noise
3. **Task 6: Misc Improvements** - No dependencies, improves existing roles
4. **Task 4: PXE Server** - No dependencies
5. **Task 1: VPN Infrastructure** - No dependencies
6. **Task 2: Kubernetes/ArgoCD** - No dependencies
7. **Task 3: Stremio RPi** - Depends on Task 2

After all PRs are merged, close PR #31 as superseded.

---

## Cleanup

After all PRs are merged:

```bash
# Remove worktrees
git worktree remove .worktrees/vpn-infra
git worktree remove .worktrees/k3s-argocd
git worktree remove .worktrees/stremio-rpi
git worktree remove .worktrees/pxe-server
git worktree remove .worktrees/dev-utils-cleanup
git worktree remove .worktrees/misc-improvements
git worktree remove .worktrees/hosts-reconciliation

# Delete local branches
git branch -D feat/vpn-infrastructure feat/k3s-argocd feat/stremio-rpi
git branch -D feat/pxe-server-improvements feat/dev-utils-cleanup feat/misc-improvements
git branch -D feat/hosts-reconciliation

# Close original PR
gh pr close 31 --comment "Superseded by smaller PRs: #32, and the feat/* branches"
```
