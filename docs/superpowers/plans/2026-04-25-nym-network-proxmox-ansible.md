# `nym_network` Proxmox Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Proxmox provisioning backend to the existing `nym_network` Ansible role, deployable via `make nym-proxmox`. Leaves the libvirt path untouched.

**Architecture:** New sibling role `proxmox_provision/` mirrors `kvm_provision/` (SSH-as-root + idempotent `qm`/`pvesh` commands; no Proxmox API token, no `community.general.proxmox_kvm`). `nym_network/` gains a `provision_backend` var that dispatches network/gateway/client/destroy tasks to either backend. Image management on Proxmox is checksum-gated and self-healing, with S3-backed images presigned per-image on the control host using a configurable AWS profile.

**Tech Stack:** Ansible (core modules + `ansible.builtin.command`/`shell` over SSH), Proxmox VE 9 (`qm`, `pvesh`, `pvesm`), AWS CLI (`aws s3 presign`, `aws sts get-caller-identity`).

**Spec:** `docs/superpowers/specs/2026-04-25-nym-network-proxmox-ansible-design.md`

**Worktree:** `~/Source_Codes/ansible-playbooks/.worktrees/nym-network-proxmox/` on branch `feat/nym-network-proxmox` (based on `feat/nym-network-ansible`).

---

## File Structure

### New files (in worktree)

```
roles/proxmox_provision/
├── defaults/main.yml          # role-level vars (ssh, storage, vmid pool, images={})
├── meta/main.yml              # role metadata
├── README.md                  # usage + per-run preflight + image-rotation steps
└── tasks/
    ├── main.yml               # orchestrator: preflight → ensure_image → snippets → vm
    ├── preflight.yml          # AWS SSO + ssh-add + SSH-reach checks
    ├── ensure_image.yml       # per-image: stat → presign (s3) → get_url
    ├── snippets.yml           # SSH-copy cicustom YAMLs to /var/lib/vz/snippets/
    ├── vm.yml                 # qm create + importdisk + set + resize + start
    └── destroy.yml            # qm stop + qm destroy --purge

roles/nym_network/tasks/
└── network-proxmox.yml        # SDN zone + vnet + apply via pvesh

playbooks/
└── nym-network-proxmox.yml    # localhost-targeted; runs nym_network with provision_backend=proxmox
```

### Modified files (in worktree)

```
Makefile                                # + PROXMOX_HOST var; + 4 targets
roles/nym_network/defaults/main.yml     # + provision_backend; + nym_network.proxmox.* sub-block
roles/nym_network/tasks/main.yml        # split network include by backend; libguestfs install conditional
roles/nym_network/tasks/gateway.yml     # split include_role by backend
roles/nym_network/tasks/client.yml      # split include_role by backend; libvirt-only steps gated
roles/nym_network/tasks/destroy.yml     # split tear-down by backend
```

### Responsibility per file

- `proxmox_provision/defaults/main.yml`: pure declaration (ssh host, datastores, vmid pool start, empty `images: {}`).
- `proxmox_provision/tasks/preflight.yml`: only checks; no state changes.
- `proxmox_provision/tasks/ensure_image.yml`: stat-then-conditionally-presign-then-get_url for one image entry; called via `loop:` over the images dict.
- `proxmox_provision/tasks/snippets.yml`: copy-to-Proxmox; conditional on cicustom path being non-empty.
- `proxmox_provision/tasks/vm.yml`: create or update one VM by `vmid`; idempotent.
- `proxmox_provision/tasks/destroy.yml`: stop + destroy one VM.
- `nym_network/tasks/network-proxmox.yml`: ensure SDN zone + vnet + apply.
- `playbooks/nym-network-proxmox.yml`: thin entrypoint: `hosts: localhost`, two roles (`config_loader`, `nym_network`).
- `Makefile`: targets and preflight.

---

## Pre-flight (manual, once before Task 1)

This plan executes inside the worktree but the worktree has no `ansible-playbook` on PATH for the bash tool. **You must run plan execution from a terminal that has ansible-playbook in PATH** (a normal interactive shell with the `.venv` activated, or after `make setup`). The Makefile already handles venv activation via `ansible_env`.

- [ ] **Confirm worktree state**

```bash
cd ~/Source_Codes/ansible-playbooks/.worktrees/nym-network-proxmox
git branch --show-current  # should print: feat/nym-network-proxmox
git log --oneline -1        # should be the spec commit (3951bf2 or later)
```

- [ ] **Confirm Proxmox-side state from the abandoned Terraform attempt is rolled back.**

If `terraform-kvm/scripts/proxmox-rollback-nym.sh` hasn't run yet, skip to it and run on the Proxmox host first. (Reachable on tailnet; if not, this whole plan is blocked anyway.)

```bash
ssh root@proxmox.ts.paulo.software.vpn 'qm list | grep -E " 200 | 201 " || echo no vmids'
ssh root@proxmox.ts.paulo.software.vpn 'pvesh get /cluster/sdn/zones --output-format json | grep -i nymz || echo no zone'
```

Expected: both report `no vmids` / `no zone`. If anything appears, run `terraform-kvm/scripts/proxmox-rollback-nym.sh` on the Proxmox host before proceeding.

---

## Task 1: Scaffold `proxmox_provision/` role with metadata, defaults, and README

**Files:**
- Create: `roles/proxmox_provision/meta/main.yml`
- Create: `roles/proxmox_provision/defaults/main.yml`
- Create: `roles/proxmox_provision/README.md`
- Create: `roles/proxmox_provision/tasks/main.yml`

- [ ] **Step 1: Create role directory structure**

```bash
cd ~/Source_Codes/ansible-playbooks/.worktrees/nym-network-proxmox
mkdir -p roles/proxmox_provision/{defaults,meta,tasks}
```

- [ ] **Step 2: Write role metadata**

Create `roles/proxmox_provision/meta/main.yml`:

```yaml
---
galaxy_info:
  role_name: proxmox_provision
  author: Paulo Francisco
  description: >
    Sibling of kvm_provision. Provisions VMs on a Proxmox VE node via SSH-as-root
    and idempotent qm/pvesh invocations. No Proxmox API token; no
    community.general.proxmox_kvm. Image management is checksum-gated and
    self-healing; S3 images are presigned on the control host using a
    configurable AWS profile.
  license: MIT
  min_ansible_version: "2.14"
  platforms:
    - name: Debian
      versions:
        - bookworm
        - trixie
  galaxy_tags:
    - proxmox
    - virtualization
    - vm
dependencies: []
```

- [ ] **Step 3: Write role defaults**

Create `roles/proxmox_provision/defaults/main.yml`:

```yaml
---
# proxmox_provision role defaults.
# Override at the playbook level or via include_role vars.

proxmox_provision:
  ssh:
    host: "proxmox.ts.paulo.software.vpn"
    user: "root"
    snippets_path: "/var/lib/vz/snippets"
    iso_path: "/var/lib/vz/template/iso"

  storage:
    iso: "local"           # where downloaded base images live
    snippets: "local"      # where cicustom YAMLs live
    vm_disk: "ceph-vms"    # where cloned VM disks live

  vmid_pool_start: 200

  # Map of logical_name → image spec.
  # Populated by the calling role (e.g., nym_network).
  # Each value is one of:
  #   { kind: http,  url, filename, sha256 }
  #   { kind: s3,    bucket, key, aws_profile, presign_expires, filename, sha256 }
  images: {}
```

- [ ] **Step 4: Write the orchestrator (`tasks/main.yml`) with no-op stubs**

Create `roles/proxmox_provision/tasks/main.yml`:

```yaml
---
# proxmox_provision dispatcher.
# Caller passes vm_name + role-level vars and includes this role.
# Operations are split into discrete includes for legibility.

- name: Run preflight checks
  ansible.builtin.include_tasks: preflight.yml
  tags: [proxmox_provision, preflight]

- name: Ensure required base images on Proxmox
  ansible.builtin.include_tasks: ensure_image.yml
  loop: "{{ proxmox_provision.images | dict2items }}"
  loop_control:
    loop_var: image_entry
    label: "{{ image_entry.key }}"
  tags: [proxmox_provision, image]
  when: proxmox_provision.images | length > 0

- name: Upload cloud-init snippets (if any)
  ansible.builtin.include_tasks: snippets.yml
  tags: [proxmox_provision, snippets]
  when:
    - vm_cloud_init_user_data is defined
    - vm_cloud_init_user_data | length > 0

- name: Provision VM
  ansible.builtin.include_tasks: vm.yml
  tags: [proxmox_provision, vm]
```

- [ ] **Step 5: Write a placeholder README**

Create `roles/proxmox_provision/README.md`:

```markdown
# proxmox_provision

Sibling of `kvm_provision`. Provisions VMs on a Proxmox VE 9 node via SSH-as-root
and idempotent `qm`/`pvesh` invocations.

**Auth model:** SSH key as root to the Proxmox host. No API tokens.

**Image management:** Checksum-gated and self-healing. HTTP-kind images downloaded
directly. S3-kind images presigned on the control host using a per-image
`aws_profile`.

## Per-run preflight (handled automatically by `_proxmox-preflight` Make target)

- AWS SSO session valid for any S3-image profiles: `aws sso login --profile <name>`
- ssh-agent loaded with the key authorized for `root@<proxmox host>`
- Proxmox host reachable via SSH

## Caller contract

The role expects these vars to be set by `include_role`:

| var | meaning |
|---|---|
| `vm_name` | VM name in Proxmox |
| `vm_role` | "gateway" or "client" (used for tagging) |
| `vmid` | Proxmox VMID |
| `vm_vcpus` | int |
| `vm_ram_mb` | int |
| `vm_disk_size` | string like "20G" |
| `vm_net` | external bridge name (e.g. `vmbr0`) |
| `vm_internal_net` | (optional) SDN vnet name for a 2nd NIC |
| `vm_cloud_init_user_data` | (optional) absolute path on control host; "" or unset = no cicustom |
| `vm_cloud_init_network_data` | (optional) absolute path on control host |
| `base_image_filename` | filename in `iso_path` to import as the boot disk |

## Role-level vars

See `defaults/main.yml`. Override `proxmox_provision.images` from the caller
to enumerate base images that should exist on the Proxmox host.
```

- [ ] **Step 6: Verify directory structure**

```bash
find roles/proxmox_provision -type f | sort
```

Expected output:
```
roles/proxmox_provision/README.md
roles/proxmox_provision/defaults/main.yml
roles/proxmox_provision/meta/main.yml
roles/proxmox_provision/tasks/main.yml
```

- [ ] **Step 7: Commit**

```bash
git add roles/proxmox_provision
git commit -m "feat(proxmox_provision): scaffold role with metadata, defaults, README, orchestrator"
```

---

## Task 2: Implement `proxmox_provision/tasks/preflight.yml`

**Files:**
- Create: `roles/proxmox_provision/tasks/preflight.yml`

- [ ] **Step 1: Write preflight tasks**

Create `roles/proxmox_provision/tasks/preflight.yml`:

```yaml
---
# Per-run preflight for proxmox_provision.
# Fails the play with actionable hints surfaced from underlying tools.

- name: "Preflight: AWS SSO sessions for S3-kind image profiles"
  delegate_to: localhost
  become: false
  ansible.builtin.command:
    cmd: "aws sts get-caller-identity --profile {{ item.aws_profile }} --query Arn --output text"
  changed_when: false
  loop: "{{ proxmox_provision.images.values() | selectattr('kind', 'equalto', 's3') | list }}"
  loop_control:
    label: "{{ item.aws_profile }}"
  register: _preflight_aws
  failed_when: _preflight_aws.rc is defined and _preflight_aws.rc != 0

- name: "Preflight: ssh-agent has at least one identity"
  delegate_to: localhost
  become: false
  ansible.builtin.command:
    cmd: "ssh-add -l"
  changed_when: false
  register: _preflight_agent
  failed_when:
    - _preflight_agent.rc != 0
    - "'no identities' not in (_preflight_agent.stderr | default(''))"
  # Note: ssh-add -l returns 1 with "The agent has no identities." when empty.
  # We accept rc==1 only if it's the "no identities" string (and then fail in next task by SSH).
  # If rc != 0 for any other reason (no agent at all), this fails.

- name: "Preflight: SSH-as-root reach to Proxmox host"
  delegate_to: localhost
  become: false
  ansible.builtin.command:
    cmd: >-
      ssh
      -o BatchMode=yes
      -o ConnectTimeout=5
      -o StrictHostKeyChecking=accept-new
      {{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}
      pveversion
  changed_when: false
  register: _preflight_ssh
  failed_when: _preflight_ssh.rc != 0
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c 'import yaml,sys; yaml.safe_load(open("roles/proxmox_provision/tasks/preflight.yml"))'
```

Expected: silent success (no output, exit 0).

- [ ] **Step 3: Commit**

```bash
git add roles/proxmox_provision/tasks/preflight.yml
git commit -m "feat(proxmox_provision): preflight checks for AWS SSO, ssh-agent, SSH reach"
```

---

## Task 3: Implement `proxmox_provision/tasks/ensure_image.yml`

**Files:**
- Create: `roles/proxmox_provision/tasks/ensure_image.yml`

- [ ] **Step 1: Write the per-image ensure logic**

Create `roles/proxmox_provision/tasks/ensure_image.yml`:

```yaml
---
# Ensure ONE image (passed as image_entry) is present on the Proxmox host with
# the expected sha256. No-op if already present and matching.
#
# image_entry is a {key, value} pair from dict2items.
# image_entry.value is one of:
#   { kind: http,  url, filename, sha256 }
#   { kind: s3,    bucket, key, aws_profile, presign_expires, filename, sha256 }

- name: "Stat existing image on Proxmox: {{ image_entry.value.filename }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.stat:
    path: "{{ proxmox_provision.ssh.iso_path }}/{{ image_entry.value.filename }}"
    checksum_algorithm: sha256
    get_checksum: true
  register: _img_stat

- name: "Set image-needed fact for {{ image_entry.key }}"
  ansible.builtin.set_fact:
    _img_needed: >-
      {{ not _img_stat.stat.exists or
         (_img_stat.stat.checksum | default('')) != image_entry.value.sha256 }}

- name: "Presign S3 URL for {{ image_entry.key }} (only if image needed)"
  delegate_to: localhost
  become: false
  ansible.builtin.command:
    cmd: >-
      aws s3 presign
      s3://{{ image_entry.value.bucket }}/{{ image_entry.value.key }}
      --expires-in {{ image_entry.value.presign_expires | default(3600) }}
      --profile {{ image_entry.value.aws_profile }}
  register: _img_presigned
  changed_when: false
  no_log: true   # presigned URL contains a signature; keep it out of logs
  when:
    - _img_needed | bool
    - image_entry.value.kind == "s3"

- name: "Resolve effective URL for {{ image_entry.key }}"
  ansible.builtin.set_fact:
    _img_effective_url: >-
      {{ _img_presigned.stdout
         if (image_entry.value.kind == 's3' and _img_needed | bool)
         else image_entry.value.url | default('') }}
  when: _img_needed | bool

- name: "Download {{ image_entry.value.filename }} on Proxmox host"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.get_url:
    url: "{{ _img_effective_url }}"
    dest: "{{ proxmox_provision.ssh.iso_path }}/{{ image_entry.value.filename }}"
    checksum: "sha256:{{ image_entry.value.sha256 }}"
    mode: "0644"
    timeout: 1800
  when: _img_needed | bool
```

- [ ] **Step 2: Verify YAML**

```bash
python3 -c 'import yaml,sys; yaml.safe_load(open("roles/proxmox_provision/tasks/ensure_image.yml"))'
```

Expected: silent success.

- [ ] **Step 3: Commit**

```bash
git add roles/proxmox_provision/tasks/ensure_image.yml
git commit -m "feat(proxmox_provision): self-healing checksum-gated image management"
```

---

## Task 4: Implement `proxmox_provision/tasks/snippets.yml`

**Files:**
- Create: `roles/proxmox_provision/tasks/snippets.yml`

- [ ] **Step 1: Write snippet upload logic**

Create `roles/proxmox_provision/tasks/snippets.yml`:

```yaml
---
# Upload cloud-init snippets to Proxmox host's snippets path.
# Caller is responsible for rendering the YAMLs to the control host first.
# Only invoked when vm_cloud_init_user_data is defined and non-empty.

- name: "Upload cicustom user-data for {{ vm_name }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.copy:
    src: "{{ vm_cloud_init_user_data }}"
    dest: "{{ proxmox_provision.ssh.snippets_path }}/{{ vm_name }}-user-data.yaml"
    mode: "0644"

- name: "Upload cicustom network-config for {{ vm_name }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.copy:
    src: "{{ vm_cloud_init_network_data }}"
    dest: "{{ proxmox_provision.ssh.snippets_path }}/{{ vm_name }}-network-config.yaml"
    mode: "0644"
  when:
    - vm_cloud_init_network_data is defined
    - vm_cloud_init_network_data | length > 0
```

- [ ] **Step 2: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("roles/proxmox_provision/tasks/snippets.yml"))'
```

Expected: silent success.

- [ ] **Step 3: Commit**

```bash
git add roles/proxmox_provision/tasks/snippets.yml
git commit -m "feat(proxmox_provision): SSH-copy cicustom snippets to Proxmox"
```

---

## Task 5: Implement `proxmox_provision/tasks/vm.yml`

**Files:**
- Create: `roles/proxmox_provision/tasks/vm.yml`

- [ ] **Step 1: Write VM lifecycle tasks**

Create `roles/proxmox_provision/tasks/vm.yml`:

```yaml
---
# Provision one VM identified by {{ vmid }}. Idempotent.
#
# Sequence:
#   1. Check existence (qm status)
#   2. If absent: qm create + qm importdisk
#   3. Always: qm set (disk + nics + cicustom)
#   4. qm resize (failed_when: false — already-at-size returns nonzero)
#   5. qm start (only if not already running)

- name: "Check VM existence: {{ vm_name }} (vmid {{ vmid }})"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: "qm status {{ vmid }}"
  register: _qm_status
  changed_when: false
  failed_when: false

- name: "Create VM shell: {{ vm_name }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: >-
      qm create {{ vmid }}
      --name {{ vm_name }}
      --cores {{ vm_vcpus }}
      --memory {{ vm_ram_mb }}
      --cpu host
      --ostype l26
      --agent enabled=1
      --serial0 socket
      --vga serial0
      --scsihw virtio-scsi-pci
      --tags "nym;{{ vm_role }}"
  when: _qm_status.rc != 0

- name: "Import boot disk for {{ vm_name }} into {{ proxmox_provision.storage.vm_disk }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: >-
      qm importdisk {{ vmid }}
      {{ proxmox_provision.ssh.iso_path }}/{{ base_image_filename }}
      {{ proxmox_provision.storage.vm_disk }}
      --format raw
  when: _qm_status.rc != 0

- name: "Attach boot disk + NICs (no cicustom): {{ vm_name }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: >-
      qm set {{ vmid }}
      --virtio0 {{ proxmox_provision.storage.vm_disk }}:vm-{{ vmid }}-disk-0,iothread=1,discard=on
      --boot order=virtio0
      --net0 virtio,bridge={{ vm_net }}
      {% if vm_internal_net is defined and vm_internal_net | length > 0 %}--net1 virtio,bridge={{ vm_internal_net }}{% endif %}
  when:
    - vm_cloud_init_user_data is not defined or vm_cloud_init_user_data | length == 0

- name: "Attach boot disk + cicustom + NICs: {{ vm_name }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: >-
      qm set {{ vmid }}
      --virtio0 {{ proxmox_provision.storage.vm_disk }}:vm-{{ vmid }}-disk-0,iothread=1,discard=on
      --boot order=virtio0
      --ide2 {{ proxmox_provision.storage.vm_disk }}:cloudinit
      --cicustom "user={{ proxmox_provision.storage.snippets }}:snippets/{{ vm_name }}-user-data.yaml,network={{ proxmox_provision.storage.snippets }}:snippets/{{ vm_name }}-network-config.yaml"
      --net0 virtio,bridge={{ vm_net }}
      {% if vm_internal_net is defined and vm_internal_net | length > 0 %}--net1 virtio,bridge={{ vm_internal_net }}{% endif %}
  when:
    - vm_cloud_init_user_data is defined
    - vm_cloud_init_user_data | length > 0

- name: "Resize disk to {{ vm_disk_size }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: "qm resize {{ vmid }} virtio0 {{ vm_disk_size }}"
  changed_when: false
  failed_when: false   # qm resize errors when already at target size

- name: "Start VM: {{ vm_name }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: "qm start {{ vmid }}"
  when: "_qm_status.rc != 0 or 'status: stopped' in (_qm_status.stdout | default(''))"
```

- [ ] **Step 2: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("roles/proxmox_provision/tasks/vm.yml"))'
```

Expected: silent success.

- [ ] **Step 3: Commit**

```bash
git add roles/proxmox_provision/tasks/vm.yml
git commit -m "feat(proxmox_provision): VM lifecycle via qm (create/import/set/resize/start)"
```

---

## Task 6: Implement `proxmox_provision/tasks/destroy.yml`

**Files:**
- Create: `roles/proxmox_provision/tasks/destroy.yml`

- [ ] **Step 1: Write teardown tasks**

Create `roles/proxmox_provision/tasks/destroy.yml`:

```yaml
---
# Tear down ONE VM by vmid. Idempotent — safe to run against absent or
# half-created state. SDN zone/vnet are NOT torn down here (other deployments
# may share). Add a separate destroy-network task if needed.

- name: "Stop VM if running: {{ vmid }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: "qm stop {{ vmid }} --skiplock"
  failed_when: false
  changed_when: false

- name: "Destroy VM: {{ vmid }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: "qm destroy {{ vmid }} --purge --skiplock"
  failed_when: false
  changed_when: false

- name: "Remove cicustom snippets for {{ vm_name }}"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - "{{ proxmox_provision.ssh.snippets_path }}/{{ vm_name }}-user-data.yaml"
    - "{{ proxmox_provision.ssh.snippets_path }}/{{ vm_name }}-network-config.yaml"
```

- [ ] **Step 2: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("roles/proxmox_provision/tasks/destroy.yml"))'
```

- [ ] **Step 3: Commit**

```bash
git add roles/proxmox_provision/tasks/destroy.yml
git commit -m "feat(proxmox_provision): destroy task — qm stop + qm destroy --purge + snippet cleanup"
```

---

## Task 7: Add `nym_network/tasks/network-proxmox.yml` (SDN zone + vnet + apply)

**Files:**
- Create: `roles/nym_network/tasks/network-proxmox.yml`

- [ ] **Step 1: Write SDN tasks**

Create `roles/nym_network/tasks/network-proxmox.yml`:

```yaml
---
# Ensure Proxmox SDN simple zone + vnet exist for the isolated nym network.
# Idempotent: each step checks-then-creates. SDN apply is always run because
# pvesh set /cluster/sdn is a no-op when nothing is pending.
#
# Constraints (Proxmox SDN):
#   - Zone and vnet IDs must be <= 8 chars, alphanumeric only.
#   - Defaults are nymz / nymiso. Override at nym_network.proxmox.* if needed.

- name: "SDN: ensure simple zone exists ({{ nym_network.proxmox.sdn_zone }})"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.shell:
    cmd: |
      pvesh get /cluster/sdn/zones/{{ nym_network.proxmox.sdn_zone }} >/dev/null 2>&1 \
        || pvesh create /cluster/sdn/zones --type simple --zone {{ nym_network.proxmox.sdn_zone }}
  register: _sdn_zone
  changed_when: "'already exists' not in (_sdn_zone.stderr | default(''))"

- name: "SDN: ensure vnet exists ({{ nym_network.proxmox.sdn_vnet }})"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.shell:
    cmd: |
      pvesh get /cluster/sdn/vnets/{{ nym_network.proxmox.sdn_vnet }} >/dev/null 2>&1 \
        || pvesh create /cluster/sdn/vnets --vnet {{ nym_network.proxmox.sdn_vnet }} --zone {{ nym_network.proxmox.sdn_zone }}
  register: _sdn_vnet
  changed_when: "'already exists' not in (_sdn_vnet.stderr | default(''))"

- name: "SDN: apply pending changes"
  delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"
  ansible.builtin.command:
    cmd: "pvesh set /cluster/sdn"
  changed_when: false
```

- [ ] **Step 2: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("roles/nym_network/tasks/network-proxmox.yml"))'
```

- [ ] **Step 3: Commit**

```bash
git add roles/nym_network/tasks/network-proxmox.yml
git commit -m "feat(nym_network): SDN zone + vnet + apply for Proxmox backend"
```

---

## Task 8: Extend `nym_network/defaults/main.yml` with `provision_backend` and `proxmox.*`

**Files:**
- Modify: `roles/nym_network/defaults/main.yml`

- [ ] **Step 1: Read current defaults**

```bash
cat roles/nym_network/defaults/main.yml
```

- [ ] **Step 2: Append new keys**

Open `roles/nym_network/defaults/main.yml` and add after the closing of the `nym_network:` mapping (preserve everything that's there). The full file becomes:

```yaml
---
# nym_network role defaults — overridden by prod-values via config_loader
# NOTE: prod-values nym_network: block replaces this dict wholesale — keep all keys.

nym_network:
  provision_backend: libvirt    # "libvirt" | "proxmox"

  libvirt_network_name: nym-network
  network_bridge: virbr-nym
  internal_cidr: 10.55.0.0/24
  internal_netmask: 255.255.255.0
  network_prefix_length: 24
  gateway_internal_ip: 10.55.0.1
  client_internal_ip: 10.55.0.10
  dns_upstream: "1.1.1.1"

  # NymVPN settings
  # REQUIRED override from prod-values; 1.4.5 is a placeholder for template rendering only
  nym_vpn_version: "1.4.5"
  nym_vpn_mode: "mixnet"
  # SENSITIVE: when set, must be provided via a SOPS-encrypted values tier
  # (e.g., prod-values/production/pc-do-b/ansible.sops.yaml), never plain values.yaml
  nym_vpn_mnemonic: ""

  # SSH public keys injected into gateway/client cloud-init
  # MUST be overridden — empty list locks you out of the VM (no console login either)
  ssh_public_keys: []

  gateway:
    name: nym-gateway
    vmid: 200
    vcpus: 2
    memory_mb: 2048
    disk_size_gb: 20
    image_url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    image_name: ubuntu-noble-nym-gateway.qcow2
    external_network: default

  client:
    name: nym-client
    vmid: 201
    vcpus: 2
    memory_mb: 4096
    base_image_path: "/var/lib/libvirt/images/kicksecure-client-base.qcow2"
    image_name: nym-client.qcow2
    hostname: nym-client

  # Proxmox-backend-specific settings.
  # Only consulted when provision_backend == "proxmox".
  proxmox:
    sdn_zone: nymz       # <= 8 chars, alphanumeric only
    sdn_vnet: nymiso     # <= 8 chars, alphanumeric only
    external_bridge: vmbr0
    images:
      gateway:
        kind: http
        url: "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
        filename: "jammy-server-cloudimg-amd64.img"
        sha256: "REPLACE_ON_FIRST_DEPLOY"
      client:
        kind: s3
        bucket: paulao-vm-images
        key: kicksecure-client-base.qcow2
        aws_profile: personal-admin-management
        presign_expires: 3600
        filename: "kicksecure-nym-client.qcow2"
        sha256: "REPLACE_ON_FIRST_DEPLOY"

# Set true to destroy+redefine the libvirt network (DANGEROUS: kills running VMs on that bridge)
nym_network_force_recreate_network: false
```

Note the `vmid` key added to both `gateway` and `client` (200 and 201) — used by the Proxmox backend; ignored by libvirt. The `sha256` placeholders are overridden in the inventory or computed during Task 14 (smoke test).

- [ ] **Step 3: Verify YAML**

```bash
python3 -c 'import yaml; print(yaml.safe_load(open("roles/nym_network/defaults/main.yml"))["nym_network"]["provision_backend"])'
```

Expected output: `libvirt`

- [ ] **Step 4: Commit**

```bash
git add roles/nym_network/defaults/main.yml
git commit -m "feat(nym_network): add provision_backend var + proxmox.* sub-block"
```

---

## Task 9: Dispatch `nym_network/tasks/main.yml` by backend

**Files:**
- Modify: `roles/nym_network/tasks/main.yml`

- [ ] **Step 1: Read current orchestrator**

```bash
cat roles/nym_network/tasks/main.yml
```

- [ ] **Step 2: Replace with backend-aware version**

Overwrite `roles/nym_network/tasks/main.yml` with:

```yaml
---
# nym_network dispatcher — orchestrates network + gateway + client provisioning.
# Backend selected by nym_network.provision_backend ("libvirt" | "proxmox").

- name: "Ensure libguestfs-tools installed (libvirt path only — needed for Kicksecure injection)"
  ansible.builtin.apt:
    name: libguestfs-tools
    state: present
    update_cache: true
    cache_valid_time: 3600
  become: true
  when: nym_network.provision_backend == "libvirt"

- name: "Define and start libvirt network"
  ansible.builtin.include_tasks: network.yml
  tags: [network]
  when: nym_network.provision_backend == "libvirt"

- name: "Ensure Proxmox SDN zone + vnet"
  ansible.builtin.include_tasks: network-proxmox.yml
  tags: [network]
  when: nym_network.provision_backend == "proxmox"

- name: "Provision gateway VM"
  ansible.builtin.include_tasks: gateway.yml
  tags: [gateway]

- name: "Provision client VM"
  ansible.builtin.include_tasks: client.yml
  tags: [client]

- name: "Destroy nym-network (tagged; never runs by default)"
  ansible.builtin.include_tasks:
    file: destroy.yml
    apply:
      tags:
        - never
        - destroy
  tags:
    - never
    - destroy
```

- [ ] **Step 3: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("roles/nym_network/tasks/main.yml"))'
```

- [ ] **Step 4: Commit**

```bash
git add roles/nym_network/tasks/main.yml
git commit -m "feat(nym_network): dispatch network setup by provision_backend"
```

---

## Task 10: Dispatch `nym_network/tasks/gateway.yml` by backend

**Files:**
- Modify: `roles/nym_network/tasks/gateway.yml`

- [ ] **Step 1: Read current**

```bash
cat roles/nym_network/tasks/gateway.yml
```

- [ ] **Step 2: Overwrite with backend-aware version**

Replace `roles/nym_network/tasks/gateway.yml` with:

```yaml
---
# Provision the nym-gateway VM. Renders cloud-init user-data on the control
# host, then dispatches to the chosen provisioning role (libvirt or proxmox).

- name: "Render gateway cloud-init user-data"
  delegate_to: localhost
  become: false
  ansible.builtin.template:
    src: gateway-user-data.yaml.j2
    dest: "/tmp/{{ nym_network.gateway.name }}-user-data.yaml"
    mode: "0644"
  register: _gw_userdata

- name: "Render gateway cloud-init network-config (Proxmox path only)"
  delegate_to: localhost
  become: false
  ansible.builtin.copy:
    dest: "/tmp/{{ nym_network.gateway.name }}-network-config.yaml"
    mode: "0644"
    content: |
      version: 2
      ethernets:
        ens18:
          dhcp4: true
          dhcp6: false
        ens19:
          addresses:
            - {{ nym_network.gateway_internal_ip }}/{{ nym_network.network_prefix_length }}
          dhcp4: false
          dhcp6: false
  when: nym_network.provision_backend == "proxmox"

- name: "Provision nym-gateway via kvm_provision (libvirt)"
  ansible.builtin.include_role:
    name: kvm_provision
  vars:
    vm_name: "{{ nym_network.gateway.name }}"
    vm_vcpus: "{{ nym_network.gateway.vcpus }}"
    vm_ram_mb: "{{ nym_network.gateway.memory_mb }}"
    vm_net: "{{ nym_network.gateway.external_network }}"
    private_network_name: "{{ nym_network.libvirt_network_name }}"
    base_image_url: "{{ nym_network.gateway.image_url }}"
    base_image_name: "{{ nym_network.gateway.image_name }}"
    vm_cloud_init_user_data: "/tmp/{{ nym_network.gateway.name }}-user-data.yaml"
  when: nym_network.provision_backend == "libvirt"

- name: "Provision nym-gateway via proxmox_provision"
  ansible.builtin.include_role:
    name: proxmox_provision
  vars:
    vm_name: "{{ nym_network.gateway.name }}"
    vm_role: "gateway"
    vmid: "{{ nym_network.gateway.vmid }}"
    vm_vcpus: "{{ nym_network.gateway.vcpus }}"
    vm_ram_mb: "{{ nym_network.gateway.memory_mb }}"
    vm_disk_size: "{{ nym_network.gateway.disk_size_gb }}G"
    vm_net: "{{ nym_network.proxmox.external_bridge }}"
    vm_internal_net: "{{ nym_network.proxmox.sdn_vnet }}"
    vm_cloud_init_user_data: "/tmp/{{ nym_network.gateway.name }}-user-data.yaml"
    vm_cloud_init_network_data: "/tmp/{{ nym_network.gateway.name }}-network-config.yaml"
    base_image_filename: "{{ nym_network.proxmox.images.gateway.filename }}"
    proxmox_provision:
      ssh:
        host: "{{ nym_network.proxmox.ssh_host | default('proxmox.ts.paulo.software.vpn') }}"
        user: "root"
        snippets_path: "/var/lib/vz/snippets"
        iso_path: "/var/lib/vz/template/iso"
      storage:
        iso: "local"
        snippets: "local"
        vm_disk: "ceph-vms"
      vmid_pool_start: 200
      images: "{{ nym_network.proxmox.images }}"
  when: nym_network.provision_backend == "proxmox"
```

- [ ] **Step 3: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("roles/nym_network/tasks/gateway.yml"))'
```

- [ ] **Step 4: Commit**

```bash
git add roles/nym_network/tasks/gateway.yml
git commit -m "feat(nym_network): dispatch gateway provisioning by backend"
```

---

## Task 11: Dispatch `nym_network/tasks/client.yml` by backend

**Files:**
- Modify: `roles/nym_network/tasks/client.yml`

- [ ] **Step 1: Overwrite with backend-aware version**

Replace `roles/nym_network/tasks/client.yml` with:

```yaml
---
# Provision the nym-client VM. Two paths:
#   - libvirt: copy + guestfish-inject + define
#   - proxmox: import pre-baked qcow2 (no cicustom; networking baked into image)

# ────────────────────────── libvirt path ──────────────────────────

- name: "(libvirt) Ensure Kicksecure base image exists on this host"
  ansible.builtin.stat:
    path: "{{ nym_network.client.base_image_path }}"
  register: _kicksecure_base
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Fail if Kicksecure base image missing"
  ansible.builtin.fail:
    msg: >-
      Kicksecure base image not found at {{ nym_network.client.base_image_path }}.
      Build it first via terraform-kvm/images/build-kicksecure-client.sh, or override
      nym_network.client.base_image_path.
  when:
    - nym_network.provision_backend == "libvirt"
    - not _kicksecure_base.stat.exists

- name: "(libvirt) Clone Kicksecure base image into ansible_pool"
  ansible.builtin.copy:
    src: "{{ nym_network.client.base_image_path }}"
    dest: "/var/lib/libvirt/images/ansible_pool/kicksecure-nym-client-base.qcow2"
    remote_src: true
    force: false
    owner: libvirt-qemu
    group: kvm
    mode: "0600"
  become: true
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Refresh ansible_pool"
  ansible.builtin.command:
    cmd: virsh -c qemu:///system pool-refresh ansible_pool
  changed_when: false
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Inject network config via guestfish"
  ansible.builtin.include_tasks: guestfish.yml
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Undefine any stale nym-client domain"
  community.libvirt.virt:
    command: undefine
    name: "{{ nym_network.client.name }}"
    flags:
      - nvram
  failed_when: false
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Define nym-client domain via kvm_provision"
  ansible.builtin.include_role:
    name: kvm_provision
  vars:
    vm_name: "{{ nym_network.client.name }}"
    vm_vcpus: "{{ nym_network.client.vcpus }}"
    vm_ram_mb: "{{ nym_network.client.memory_mb }}"
    vm_net: "{{ nym_network.libvirt_network_name }}"
    vm_cloud_init_user_data: ""
    base_image_url: ""
    base_image_name: "kicksecure-nym-client-base.qcow2"
    vm_disk_size: "100G"
  when: nym_network.provision_backend == "libvirt"

# ────────────────────────── proxmox path ──────────────────────────

- name: "(proxmox) Provision nym-client via proxmox_provision"
  ansible.builtin.include_role:
    name: proxmox_provision
  vars:
    vm_name: "{{ nym_network.client.name }}"
    vm_role: "client"
    vmid: "{{ nym_network.client.vmid }}"
    vm_vcpus: "{{ nym_network.client.vcpus }}"
    vm_ram_mb: "{{ nym_network.client.memory_mb }}"
    vm_disk_size: "30G"
    vm_net: "{{ nym_network.proxmox.sdn_vnet }}"
    # No vm_internal_net — client is single-NIC.
    vm_cloud_init_user_data: ""    # Kicksecure has networking baked in
    vm_cloud_init_network_data: ""
    base_image_filename: "{{ nym_network.proxmox.images.client.filename }}"
    proxmox_provision:
      ssh:
        host: "{{ nym_network.proxmox.ssh_host | default('proxmox.ts.paulo.software.vpn') }}"
        user: "root"
        snippets_path: "/var/lib/vz/snippets"
        iso_path: "/var/lib/vz/template/iso"
      storage:
        iso: "local"
        snippets: "local"
        vm_disk: "ceph-vms"
      vmid_pool_start: 200
      images: "{{ nym_network.proxmox.images }}"
  when: nym_network.provision_backend == "proxmox"
```

- [ ] **Step 2: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("roles/nym_network/tasks/client.yml"))'
```

- [ ] **Step 3: Commit**

```bash
git add roles/nym_network/tasks/client.yml
git commit -m "feat(nym_network): dispatch client provisioning by backend"
```

---

## Task 12: Dispatch `nym_network/tasks/destroy.yml` by backend

**Files:**
- Modify: `roles/nym_network/tasks/destroy.yml`

- [ ] **Step 1: Overwrite with backend-aware version**

Replace `roles/nym_network/tasks/destroy.yml` with:

```yaml
---
# Tear down nym-network resources. Idempotent — safe against partial state.
# SDN zone/vnet are NOT torn down on the proxmox path (other deployments may share).

# ────────────────────────── libvirt path ──────────────────────────

- name: "(libvirt) Stop nym-gateway domain"
  community.libvirt.virt:
    command: destroy
    name: "{{ nym_network.gateway.name }}"
  failed_when: false
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Undefine nym-gateway domain (with NVRAM)"
  community.libvirt.virt:
    command: undefine
    name: "{{ nym_network.gateway.name }}"
    flags:
      - nvram
  failed_when: false
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Stop nym-client domain"
  community.libvirt.virt:
    command: destroy
    name: "{{ nym_network.client.name }}"
  failed_when: false
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Undefine nym-client domain (with NVRAM)"
  community.libvirt.virt:
    command: undefine
    name: "{{ nym_network.client.name }}"
    flags:
      - nvram
  failed_when: false
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Remove VM volumes"
  ansible.builtin.file:
    path: "{{ libvirt_pool_dir | default('/var/lib/libvirt/images') }}/{{ item }}"
    state: absent
  loop:
    - "{{ nym_network.gateway.image_name }}"
    - "{{ nym_network.gateway.name }}_cidata.iso"
    - "{{ nym_network.client.image_name }}"
  become: true
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Stop nym libvirt network"
  community.libvirt.virt_net:
    name: "{{ nym_network.libvirt_network_name }}"
    state: inactive
  failed_when: false
  when: nym_network.provision_backend == "libvirt"

- name: "(libvirt) Undefine nym libvirt network"
  community.libvirt.virt_net:
    name: "{{ nym_network.libvirt_network_name }}"
    state: absent
  failed_when: false
  when: nym_network.provision_backend == "libvirt"

# ────────────────────────── proxmox path ──────────────────────────

- name: "(proxmox) Destroy nym-gateway VM"
  ansible.builtin.include_role:
    name: proxmox_provision
    tasks_from: destroy.yml
  vars:
    vm_name: "{{ nym_network.gateway.name }}"
    vmid: "{{ nym_network.gateway.vmid }}"
    proxmox_provision:
      ssh:
        host: "{{ nym_network.proxmox.ssh_host | default('proxmox.ts.paulo.software.vpn') }}"
        user: "root"
        snippets_path: "/var/lib/vz/snippets"
        iso_path: "/var/lib/vz/template/iso"
      storage:
        iso: "local"
        snippets: "local"
        vm_disk: "ceph-vms"
      vmid_pool_start: 200
      images: {}
  when: nym_network.provision_backend == "proxmox"

- name: "(proxmox) Destroy nym-client VM"
  ansible.builtin.include_role:
    name: proxmox_provision
    tasks_from: destroy.yml
  vars:
    vm_name: "{{ nym_network.client.name }}"
    vmid: "{{ nym_network.client.vmid }}"
    proxmox_provision:
      ssh:
        host: "{{ nym_network.proxmox.ssh_host | default('proxmox.ts.paulo.software.vpn') }}"
        user: "root"
        snippets_path: "/var/lib/vz/snippets"
        iso_path: "/var/lib/vz/template/iso"
      storage:
        iso: "local"
        snippets: "local"
        vm_disk: "ceph-vms"
      vmid_pool_start: 200
      images: {}
  when: nym_network.provision_backend == "proxmox"
```

- [ ] **Step 2: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("roles/nym_network/tasks/destroy.yml"))'
```

- [ ] **Step 3: Commit**

```bash
git add roles/nym_network/tasks/destroy.yml
git commit -m "feat(nym_network): dispatch destroy by backend"
```

---

## Task 13: Add `playbooks/nym-network-proxmox.yml`

**Files:**
- Create: `playbooks/nym-network-proxmox.yml`

- [ ] **Step 1: Write the playbook**

Create `playbooks/nym-network-proxmox.yml`:

```yaml
---
# Provision the NymVPN gateway + Kicksecure client on a Proxmox VE 9 host.
#
# Usage:
#   make nym-proxmox-check                # dry-run (--check mode)
#   make nym-proxmox                      # apply
#   make nym-proxmox-destroy              # tear down VMs (SDN survives)
#
# All actions are delegate_to root@<proxmox host>; this play targets localhost
# and does not consume any Ansible host inventory beyond the control machine.

- name: "Provision nym-network on Proxmox"
  hosts: localhost
  connection: local
  gather_facts: false

  vars_files: []   # add SOPS-encrypted vars files here if applicable

  pre_tasks:
    - name: "Force provision_backend = proxmox for this play"
      ansible.builtin.set_fact:
        nym_network_force_backend: proxmox

  roles:
    - role: config_loader
      vars:
        config_store_path: "{{ lookup('env', 'CONFIG_STORE') | default('', true) }}"
        config_environment: production

    - role: nym_network
      vars:
        nym_network:
          provision_backend: "{{ nym_network_force_backend }}"
          # Other keys: inherit from config_loader / role defaults.
          # If config_loader replaces nym_network: wholesale, ensure the
          # production values include provision_backend: proxmox for this host.
```

Note on `nym_network_force_backend`: the play sets it as a pre-task fact then references it in role vars. This is a workaround for `config_loader` replacing the entire `nym_network:` mapping; if that turns out not to be needed (i.e. config_loader merges instead of replaces), simplify to `provision_backend: proxmox` directly. Verify in Task 14.

- [ ] **Step 2: Verify YAML**

```bash
python3 -c 'import yaml; yaml.safe_load(open("playbooks/nym-network-proxmox.yml"))'
```

- [ ] **Step 3: Commit**

```bash
git add playbooks/nym-network-proxmox.yml
git commit -m "feat(playbooks): nym-network-proxmox.yml entrypoint (localhost-targeted)"
```

---

## Task 14: Add Makefile targets

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Read current Makefile end**

```bash
tail -25 Makefile
```

- [ ] **Step 2: Append new section**

Append to `Makefile` (preserve everything above; this is additive):

```make

# ─── Proxmox host (overridable: PROXMOX_HOST=other.example.com make nym-proxmox) ───
PROXMOX_HOST ?= proxmox.ts.paulo.software.vpn

.PHONY: nym-proxmox nym-proxmox-check nym-proxmox-destroy _proxmox-preflight

_proxmox-preflight:
	@aws sts get-caller-identity --profile $(AWS_PROFILE) >/dev/null 2>&1 \
	  || { echo "❌ AWS SSO expired. Run: aws sso login --profile $(AWS_PROFILE)"; exit 1; }
	@ssh-add -l >/dev/null 2>&1 \
	  || { echo "❌ ssh-agent has no identity. Run: eval \"\$$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519"; exit 1; }
	@ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@$(PROXMOX_HOST) hostname >/dev/null 2>&1 \
	  || { echo "❌ Cannot reach root@$(PROXMOX_HOST) via SSH."; exit 1; }
	@echo "✅ Preflight passed: AWS SSO, ssh-agent, Proxmox reachable"

nym-proxmox-check: _proxmox-preflight
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) --check playbooks/nym-network-proxmox.yml $(ARGS)

nym-proxmox: _proxmox-preflight
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/nym-network-proxmox.yml $(ARGS)

nym-proxmox-destroy: _proxmox-preflight
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) --tags destroy playbooks/nym-network-proxmox.yml $(ARGS)
```

- [ ] **Step 3: Verify Makefile parses**

```bash
make -n nym-proxmox-check
```

Expected: prints the commands that would run (preflight + ansible-playbook), no errors.

- [ ] **Step 4: Verify preflight target works**

```bash
make _proxmox-preflight
```

Expected (assuming SSO + ssh-agent + tailnet are healthy):
```
✅ Preflight passed: AWS SSO, ssh-agent, Proxmox reachable
```

If any check fails, fix the underlying condition (run `aws sso login`, start ssh-agent, troubleshoot tailnet) before continuing.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "feat(Makefile): nym-proxmox / nym-proxmox-check / nym-proxmox-destroy targets"
```

---

## Task 15: Pin image checksums

**Files:**
- Modify: `roles/nym_network/defaults/main.yml` (replace `REPLACE_ON_FIRST_DEPLOY` strings)

This task computes real checksums for the two base images and pins them in defaults.

- [ ] **Step 1: Verify Proxmox is reachable**

```bash
ssh root@proxmox.ts.paulo.software.vpn pveversion
```

Expected: prints something like `pve-manager/9.x...`. If unreachable, defer this task until tailnet is back.

- [ ] **Step 2: Get Ubuntu jammy SHA256**

The Ubuntu cloud-images site publishes `SHA256SUMS` at the same URL prefix:

```bash
curl -fsSL https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS \
  | grep 'jammy-server-cloudimg-amd64.img$' \
  | awk '{print $1}'
```

Expected: a 64-char hex sha256. Capture as `$GATEWAY_SHA`.

- [ ] **Step 3: Get Kicksecure SHA256**

If the image is currently on the Proxmox host (pre-seeded earlier), compute it remotely:

```bash
ssh root@proxmox.ts.paulo.software.vpn \
  'sha256sum /var/lib/vz/template/iso/kicksecure-nym-client.qcow2 2>/dev/null | awk "{print \$1}"'
```

If the image is NOT present on Proxmox (rolled back), fall back to computing against S3:

```bash
URL=$(AWS_PROFILE=personal-admin-management aws s3 presign s3://paulao-vm-images/kicksecure-client-base.qcow2 --expires-in 600)
curl -fsSL "$URL" | sha256sum | awk '{print $1}'
```

Capture as `$CLIENT_SHA`.

- [ ] **Step 4: Replace placeholders in defaults**

Edit `roles/nym_network/defaults/main.yml`:

Replace the line `sha256: "REPLACE_ON_FIRST_DEPLOY"` under `nym_network.proxmox.images.gateway` with:

```yaml
        sha256: "<paste $GATEWAY_SHA>"
```

Replace the line `sha256: "REPLACE_ON_FIRST_DEPLOY"` under `nym_network.proxmox.images.client` with:

```yaml
        sha256: "<paste $CLIENT_SHA>"
```

- [ ] **Step 5: Verify YAML**

```bash
python3 -c 'import yaml; d = yaml.safe_load(open("roles/nym_network/defaults/main.yml")); \
  print(d["nym_network"]["proxmox"]["images"]["gateway"]["sha256"]); \
  print(d["nym_network"]["proxmox"]["images"]["client"]["sha256"])'
```

Expected: two 64-char hex strings (no `REPLACE_ON_FIRST_DEPLOY`).

- [ ] **Step 6: Commit**

```bash
git add roles/nym_network/defaults/main.yml
git commit -m "feat(nym_network): pin sha256 for jammy + kicksecure images"
```

---

## Task 16: Smoke test — `make nym-proxmox-check`

**Files:** none modified — verification only.

- [ ] **Step 1: Verify preflight + dry-run plan**

```bash
make nym-proxmox-check
```

Expected:
- Preflight prints `✅ Preflight passed: ...`
- `ansible-playbook --check` runs through preflight tasks (AWS sts, ssh-add -l, ssh hostname all return 0).
- ensure_image tasks evaluate the stat against Proxmox; they may report "would change" if the images aren't already present at matching checksums (acceptable in --check).
- VM tasks may report errors in --check because shell tasks don't always run in check mode; those are expected limitations of `--check`.

What is NOT acceptable in `--check`:
- Preflight failures.
- Any task failing on a YAML or template syntax error.
- Any task referencing an undefined variable.

If any of these surface, fix before Task 17.

- [ ] **Step 2: Commit anything you fixed**

If Step 1 surfaced bugs and you fixed them:

```bash
git add -p
git commit -m "fix(nym-proxmox): <describe what was broken>"
```

---

## Task 17: Smoke test — `make nym-proxmox` (real deploy)

**Files:** none modified — actual deploy.

- [ ] **Step 1: Apply**

```bash
make nym-proxmox
```

Expected behavior, in order:
1. Preflight: `✅ Preflight passed`
2. SDN zone + vnet creation (or "already exists" no-op).
3. Image stat → both images come back with matching sha256 (no download). If sha256 mismatched (or images absent because of earlier rollback), download proceeds: ~2 min for jammy (~700 MB), ~3-5 min for kicksecure (~1.5 GB). Re-runs of make nym-proxmox after this skip download.
4. Snippets uploaded to Proxmox `/var/lib/vz/snippets/`.
5. Gateway VM created (`qm create` + `qm importdisk` + `qm set` + `qm resize` + `qm start`).
6. Client VM created similarly (no cicustom).
7. Play summary: `failed=0`, `unreachable=0`.

Total: ~8-12 minutes on first run, ~2 minutes on idempotent re-runs.

- [ ] **Step 2: Verify gateway is up**

Wait ~2 minutes after `make nym-proxmox` finishes for cloud-init to install qemu-guest-agent.

```bash
ssh root@proxmox.ts.paulo.software.vpn 'qm guest cmd 200 ping'
```

Expected: `{}` (empty object = success).

If "QEMU guest agent is not running", give it another 60s. If still failing after 5 min total, cloud-init may have hung. SSH directly to the VM to investigate:

```bash
ssh root@proxmox.ts.paulo.software.vpn 'qm guest cmd 200 network-get-interfaces' \
  | python3 -c 'import sys, json; print([a["ip-address"] for i in json.load(sys.stdin) for a in i.get("ip-addresses", []) if a["ip-address-type"]=="ipv4" and not a["ip-address"].startswith("127")])'
```

- [ ] **Step 3: Verify client connectivity**

```bash
ssh root@proxmox.ts.paulo.software.vpn 'qm guest cmd 201 ping' || echo "client agent absent (acceptable for Kicksecure)"
ssh ubuntu@<gateway-LAN-IP> 'ping -c 3 10.55.0.10'
```

Expected: 0% packet loss.

- [ ] **Step 4: Verify kill switch**

```bash
ssh ubuntu@<gateway-LAN-IP> 'sudo systemctl stop nym-vpn'
# Then from client (via gateway SSH-jump or VNC console):
# curl --max-time 5 ifconfig.me
# Expected: timeout. If it succeeds with your home IP, the kill switch is broken.
ssh ubuntu@<gateway-LAN-IP> 'sudo systemctl start nym-vpn'
```

- [ ] **Step 5: Verify idempotence**

Re-run with no changes:

```bash
make nym-proxmox
```

Expected: very fast (~30s); summary shows `changed=0` or only `qm set` reporting changes (qm set is not perfectly idempotent in our model — accept up to 5 changes per VM from re-running `qm set`).

---

## Task 18: Smoke test — destroy and redeploy

**Files:** none modified — verification.

- [ ] **Step 1: Destroy**

```bash
make nym-proxmox-destroy
```

Expected: VMs 200 and 201 stopped + destroyed; cicustom snippets removed. SDN survives.

```bash
ssh root@proxmox.ts.paulo.software.vpn 'qm list | awk "NR==1 || \$1==200 || \$1==201"'
```

Expected: only header row.

- [ ] **Step 2: Redeploy clean**

```bash
make nym-proxmox
```

Expected: same flow as Task 17 step 1, but image stat finds existing images (sha256 matches) and skips download. ~3-5 min total.

- [ ] **Step 3: If anything broke, fix and re-commit**

Any bugs surfaced in Tasks 17-18 should be fixed and committed. Tag commits as `fix(nym-proxmox): <thing>`.

---

## Self-review against the spec

### Spec coverage

| Spec section | Implementing task |
|---|---|
| Goal: deploy gateway + client on Proxmox via Ansible | Tasks 1–13 |
| Goal: reuse existing nym_network role's content | Tasks 9–12 (dispatcher edits, no template changes) |
| Goal: backend selectable per-host via single var | Task 8 (`provision_backend`) + dispatcher Tasks 9–12 |
| Goal: SSH-as-root only, no API token | Tasks 2, 5, 6, 7 (all delegate_to root@ssh.host) |
| Goal: image management self-healing checksum-gated | Task 3 |
| Goal: S3 presigning per-image profile on control host | Task 3 (presign step `delegate_to: localhost`) |
| Goal: preflight failures loud and actionable | Tasks 2, 14 (Makefile preflight) |
| Architecture: new sibling role + dispatcher edits | Tasks 1–7 (new) + 8–12 (edits) |
| Topology: SDN zone + vnet + 2 VMs + ceph-vms disks | Tasks 7, 10, 11 |
| Backend dispatch: single `provision_backend` var | Tasks 8, 9, 10, 11, 12 |
| `proxmox_provision` role contract: caller vars | Task 1 (README), used in Tasks 10, 11, 12 |
| Auth model: SSH key as root | Implicit in every `delegate_to` |
| Data flow: gateway / client / SDN | Tasks 7, 10, 11 |
| Error handling: surface upstream errors | Tasks 2 (failed_when on AWS sts), 5 (qm errors propagate), 14 (Makefile hints) |
| Testing: syntax / dry-run / smoke / destroy+redeploy | Tasks 16, 17, 18 |
| Security: SSH-only auth, SOPS for sensitive vars | Out of code scope; existing pattern preserved |
| Pre-flight: AWS SSO + ssh-agent + Proxmox reach | Tasks 2 (Ansible-side), 14 (Makefile-side) |
| Risk #5 (qm importdisk half-completes) | Task 17 covers detection; recovery path is `make nym-proxmox-destroy && make nym-proxmox` |
| Decisions table: 15 decisions | All 15 reflected in code; spot-check by reading the spec's Decisions table against the relevant tasks |
| Makefile integration | Task 14 |

No gaps identified.

### Placeholder scan

Every code step shows actual code or actual commands with expected output. Two intentional `REPLACE_ON_FIRST_DEPLOY` strings in Task 8 are explicitly resolved in Task 15 (with a real script to compute the values). Not placeholders in the "filling in later" sense — they're parameters with a deterministic resolution path.

No "TODO", no "TBD", no "similar to Task N", no "appropriate error handling".

### Type consistency

- `vmid` (number) — used identically in Tasks 5, 6, 8, 10, 11, 12.
- `proxmox_provision.ssh.host` / `.user` / `.snippets_path` / `.iso_path` — same nested keys in defaults (Task 1) and consumers (Tasks 2, 3, 4, 5, 6, 7, 10, 11, 12).
- `nym_network.proxmox.images.{gateway,client}.{kind,filename,sha256}` — same shape in defaults (Task 8) and consumers (Tasks 3, 10, 11).
- Tag string `nym;<vm_role>` — Task 5 uses `vm_role`; Task 10 passes `vm_role: "gateway"`; Task 11 passes `vm_role: "client"`. Consistent.

No drift found.

### Scope check

One implementation plan covering one sub-project (Proxmox backend for nym_network). Not breakable further without artificial fragmentation.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-25-nym-network-proxmox-ansible.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
