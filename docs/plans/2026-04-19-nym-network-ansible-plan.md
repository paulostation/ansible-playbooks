# nym-network Ansible Role Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the `terraform-kvm/modules/nym-network` Terraform module to an Ansible role in `ansible-playbooks`, eliminating the libvirt Terraform provider workarounds (dropped `<graphics>`, null_resource guestfish shim, `ignore_changes` hack).

**Architecture:** New `nym_network` role composes existing `kvm_provision` role via `include_role` for generic VM lifecycle. Role-specific tasks handle the libvirt network (`virbr-nym`), Kicksecure client's guestfish network injection, and gateway cloud-init rendering. Values sourced from `prod-values/production/pc-do-b/values.yaml` via the existing `config_loader` role. Single orchestrating playbook `playbooks/nym-network.yml`.

**Tech Stack:** Ansible 2.x, `community.libvirt` collection (`virt_net`, `virt`, `virt_pool`), `community.sops` vars plugin, `ansible.builtin.template`, Jinja2, guestfish (via `libguestfs-tools` apt package).

**Design doc:** `docs/plans/2026-04-19-nym-network-ansible-design.md`

**Repo layout:**
```
~/Source_Codes/mein/ansible-playbooks/     # roles, playbooks, hosts.yml
~/Source_Codes/mein/prod-values/           # values.yaml tiers, consumed by config_loader
~/Source_Codes/mein/terraform-kvm/          # Terraform module being replaced (source of truth for reference)
```

**Conventions observed in the repo:**
- Roles live under `ansible-playbooks/roles/`, playbooks under `playbooks/`
- Jinja2 templates in `<role>/templates/`, default vars in `<role>/defaults/main.yml`
- SOPS-encrypted secrets files end in `.sops.yml` or `.sops.yaml`, decrypted by the `community.sops.sops` vars plugin configured in `ansible.cfg`
- Commits in ansible-playbooks are signed-off conventional commits (see recent history on `main`)

---

### Task 0: Pre-implementation cleanup — rename `omarchy-pc-do-b` → `pc-do-b`

**Rationale:** inventory names match tailscale names (user preference). The existing `omarchy-pc-do-b` entry is a stale stub with placeholder data; the actual hypervisor is `pc-do-b` (tailnet `100.64.7.6`, LAN `192.168.15.106`).

**Files:**
- Modify: `~/Source_Codes/mein/ansible-playbooks/hosts.yml` (line ~27: `omarchy-pc-do-b:` → `pc-do-b:` with `ansible_host`)
- Modify: `~/Source_Codes/mein/prod-values/values.yaml` (line ~27: `vpn.peers` entry)
- Modify: `~/Source_Codes/mein/prod-values/production/secrets.sops.yaml` (remove `omarchy-pc-do-b` encrypted key)
- Delete: `~/Source_Codes/mein/prod-values/production/omarchy-pc-do-b/` (directory + contents)
- Create: `~/Source_Codes/mein/prod-values/production/pc-do-b/` (empty dir for Task 1)

- [ ] **Step 1: Update `ansible-playbooks/hosts.yml`**

In `~/Source_Codes/mein/ansible-playbooks/hosts.yml`, find the line `        omarchy-pc-do-b:` under `home.hosts` and replace with:

```yaml
        pc-do-b:
          ansible_host: pc-do-b.ts.paulo.software.vpn
```

Run:
```bash
cd ~/Source_Codes/mein/ansible-playbooks
sed -i 's|^        omarchy-pc-do-b:$|        pc-do-b:\n          ansible_host: pc-do-b.ts.paulo.software.vpn|' hosts.yml
grep -A 1 "pc-do-b" hosts.yml | head -5
```

Expected output contains:
```
        pc-do-b:
          ansible_host: pc-do-b.ts.paulo.software.vpn
```

- [ ] **Step 2: Update `prod-values/values.yaml` vpn.peers**

Find the line `    - { name: omarchy-pc-do-b, ip: "100.64.7.7" }` and change the name to `pc-do-b` and the IP to `100.64.7.6` (actual tailnet IP).

Run:
```bash
cd ~/Source_Codes/mein/prod-values
sed -i 's|{ name: omarchy-pc-do-b, ip: "100.64.7.7" }|{ name: pc-do-b, ip: "100.64.7.6" }|' values.yaml
grep "pc-do-b" values.yaml
```

Expected output:
```
    - { name: pc-do-b, ip: "100.64.7.6" }
```

- [ ] **Step 3: Remove `omarchy-pc-do-b` from `production/secrets.sops.yaml`**

The file is SOPS-encrypted. To edit:

```bash
cd ~/Source_Codes/mein/prod-values
sops production/secrets.sops.yaml
```

In the editor, remove the line starting `            omarchy-pc-do-b: ENC[...]`. Save and exit.

Verify the entry is gone:
```bash
sops -d production/secrets.sops.yaml | grep -c "omarchy-pc-do-b" || echo "0"
```

Expected output: `0`

- [ ] **Step 4: Remove the stale directory**

```bash
cd ~/Source_Codes/mein/prod-values
rm -rf production/omarchy-pc-do-b/
mkdir -p production/pc-do-b/
ls production/ | grep -E "pc-do-b|omarchy-pc-do-b"
```

Expected output: `pc-do-b` (and no `omarchy-pc-do-b`).

- [ ] **Step 5: Commit both repos**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add hosts.yml
git commit -m "inventory: rename omarchy-pc-do-b → pc-do-b (match tailscale)"

cd ~/Source_Codes/mein/prod-values
git add values.yaml production/secrets.sops.yaml production/
git commit -m "config: rename omarchy-pc-do-b → pc-do-b, remove stale stub"
```

Expected: both commits succeed.

---

### Task 1: Create `prod-values/production/pc-do-b/values.yaml` with `nym_network` block

**Files:**
- Create: `~/Source_Codes/mein/prod-values/production/pc-do-b/values.yaml`

- [ ] **Step 1: Write the values file**

Create `~/Source_Codes/mein/prod-values/production/pc-do-b/values.yaml`:

```yaml
# Host-level values for pc-do-b (Ubuntu hypervisor, 192.168.15.106)
# Consumed by Ansible via config_loader role. Helm ignores unknown keys.

nym_network:
  libvirt_network_name: nym-network
  network_bridge: virbr-nym
  internal_cidr: 10.55.0.0/24
  internal_netmask: 255.255.255.0
  gateway_internal_ip: 10.55.0.1
  client_internal_ip: 10.55.0.10
  dns_upstream: "1.1.1.1"

  gateway:
    name: nym-gateway
    vcpus: 2
    memory_mb: 2048
    disk_size_gb: 20
    image_url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    image_name: ubuntu-noble-nym-gateway.qcow2
    external_network: default

  client:
    name: nym-client
    vcpus: 2
    memory_mb: 4096
    base_image_path: "/var/lib/libvirt/images/kicksecure-client-base.qcow2"
    image_name: nym-client.qcow2
    hostname: nym-client
```

- [ ] **Step 2: Commit**

```bash
cd ~/Source_Codes/mein/prod-values
git add production/pc-do-b/values.yaml
git commit -m "pc-do-b: add nym_network values for Ansible role"
```

Expected: one commit, one file changed.

---

### Task 2: Scaffold `nym_network` role directory structure

**Files:**
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/defaults/main.yml`
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/meta/main.yml`
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/main.yml` (empty dispatcher for now)
- Create: directory `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/`
- Create: directory `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/files/`

- [ ] **Step 1: Make the directory tree**

```bash
cd ~/Source_Codes/mein/ansible-playbooks/roles
mkdir -p nym_network/{defaults,meta,tasks,templates,files}
```

- [ ] **Step 2: Write `defaults/main.yml`**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/defaults/main.yml`:

```yaml
---
# nym_network role defaults — overridden by prod-values via config_loader

nym_network:
  libvirt_network_name: nym-network
  network_bridge: virbr-nym
  internal_cidr: 10.55.0.0/24
  internal_netmask: 255.255.255.0
  gateway_internal_ip: 10.55.0.1
  client_internal_ip: 10.55.0.10
  dns_upstream: "1.1.1.1"

  gateway:
    name: nym-gateway
    vcpus: 2
    memory_mb: 2048
    disk_size_gb: 20
    image_url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    image_name: ubuntu-noble-nym-gateway.qcow2
    external_network: default

  client:
    name: nym-client
    vcpus: 2
    memory_mb: 4096
    base_image_path: "/var/lib/libvirt/images/kicksecure-client-base.qcow2"
    image_name: nym-client.qcow2
    hostname: nym-client

nym_network_force_recreate_network: false
```

- [ ] **Step 3: Write `meta/main.yml`**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/meta/main.yml`:

```yaml
---
galaxy_info:
  author: paulao
  description: Provisions NymVPN gateway + Kicksecure client VMs on a libvirt host
  license: MIT
  min_ansible_version: "2.14"
  platforms:
    - name: Ubuntu
      versions:
        - "22.04"
        - "24.04"

dependencies: []
```

- [ ] **Step 4: Write empty `tasks/main.yml` dispatcher**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/main.yml`:

```yaml
---
# nym_network dispatcher — orchestrates network + gateway + client provisioning

- name: Ensure libguestfs-tools installed (for Kicksecure client network injection)
  ansible.builtin.apt:
    name: libguestfs-tools
    state: present
    update_cache: yes
    cache_valid_time: 3600
  become: true

- name: Define and start libvirt network
  ansible.builtin.include_tasks: network.yml
  tags: [network]

- name: Provision gateway VM
  ansible.builtin.include_tasks: gateway.yml
  tags: [gateway]

- name: Provision client VM
  ansible.builtin.include_tasks: client.yml
  tags: [client]
```

- [ ] **Step 5: Commit**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/nym_network/
git commit -m "nym_network: scaffold role structure + defaults"
```

Expected: one commit, 3 files + 2 empty dirs.

---

### Task 3: Implement libvirt network definition (`tasks/network.yml` + template)

**Files:**
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/libvirt-nym-network.xml.j2`
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/network.yml`

**Reference:** terraform-kvm `modules/nym-network/main.tf` `libvirt_network.nym_network` resource.

- [ ] **Step 1: Create the XML template**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/libvirt-nym-network.xml.j2`:

```xml
<network>
  <name>{{ nym_network.libvirt_network_name }}</name>
  <bridge name="{{ nym_network.network_bridge }}" stp="on" delay="0"/>
  <forward mode="none"/>
  <ip address="{{ nym_network.gateway_internal_ip }}" netmask="{{ nym_network.internal_netmask }}">
  </ip>
</network>
```

Notes:
- `forward mode="none"` creates an isolated network (no NAT), matching terraform-kvm's `libvirt_network` without `forward` block.
- No `<dhcp>` — the client uses static IPs via guestfish.

- [ ] **Step 2: Write `tasks/network.yml`**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/network.yml`:

```yaml
---
# Define and start the nym-network libvirt network

- name: Gather current libvirt network facts
  community.libvirt.virt_net:
    command: facts
  register: _net_facts

- name: Define nym libvirt network (idempotent)
  community.libvirt.virt_net:
    command: define
    name: "{{ nym_network.libvirt_network_name }}"
    xml: "{{ lookup('template', 'libvirt-nym-network.xml.j2') }}"

- name: Start nym libvirt network
  community.libvirt.virt_net:
    command: create
    name: "{{ nym_network.libvirt_network_name }}"
  register: _net_start
  failed_when:
    - _net_start.failed | default(false)
    - "'already active' not in (_net_start.msg | default(''))"

- name: Mark nym libvirt network autostart
  community.libvirt.virt_net:
    autostart: true
    name: "{{ nym_network.libvirt_network_name }}"
```

Notes:
- `command: define` is idempotent (replaces definition if XML differs, but for active network Ansible will fail — that's desired behavior so we don't accidentally reconfigure).
- `command: create` = start (libvirt's inconsistent terminology). The `failed_when` guards against "already active" on re-runs.

- [ ] **Step 3: Commit**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/nym_network/templates/libvirt-nym-network.xml.j2 roles/nym_network/tasks/network.yml
git commit -m "nym_network: libvirt network definition + task"
```

---

### Task 4: Port gateway cloud-init user-data template

**Files:**
- Read: `~/Source_Codes/mein/terraform-kvm/modules/nym-network/cloud-init/gateway-user-data.yaml` (source of truth)
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/gateway-user-data.yaml.j2`

- [ ] **Step 1: Read the Terraform source to know what to port**

```bash
cat ~/Source_Codes/mein/terraform-kvm/modules/nym-network/cloud-init/gateway-user-data.yaml
```

Note the Terraform interpolations (e.g., `${gateway_internal_ip}`, `${client_internal_ip}`, `${dns_upstream}`) — these become Jinja2 `{{ nym_network.gateway_internal_ip }}` etc.

- [ ] **Step 2: Create the Jinja2 template**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/gateway-user-data.yaml.j2`. Copy the Terraform file's contents, then replace Terraform interpolation syntax:

- `${gateway_internal_ip}` → `{{ nym_network.gateway_internal_ip }}`
- `${client_internal_ip}` → `{{ nym_network.client_internal_ip }}`
- `${dns_upstream}` → `{{ nym_network.dns_upstream }}`
- `${internal_cidr}` → `{{ nym_network.internal_cidr }}`
- Any other `${...}` → corresponding `{{ nym_network.X }}`

Add at the top (Jinja2 comment, not emitted):
```
#jinja2: lstrip_blocks: True, trim_blocks: True
#cloud-config
```

(Keep the `#cloud-config` cloud-init header on line 2.)

- [ ] **Step 3: Verify template renders**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
ansible localhost -m template -a "src=roles/nym_network/templates/gateway-user-data.yaml.j2 dest=/tmp/rendered-gateway-userdata.yaml" \
  -e "@/tmp/test-vars.yaml" \
  --check --diff 2>&1 | head -20
```

First create `/tmp/test-vars.yaml` with role defaults for the test:
```yaml
nym_network:
  gateway_internal_ip: "10.55.0.1"
  client_internal_ip: "10.55.0.10"
  dns_upstream: "1.1.1.1"
  internal_cidr: "10.55.0.0/24"
```

Expected: template renders without `undefined variable` errors.

- [ ] **Step 4: Commit**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/nym_network/templates/gateway-user-data.yaml.j2
git commit -m "nym_network: port gateway cloud-init user-data to Jinja2"
```

---

### Task 5: Implement gateway VM provisioning (`tasks/gateway.yml`)

**Files:**
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/gateway.yml`

- [ ] **Step 1: Write gateway.yml**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/gateway.yml`:

```yaml
---
# Provision nym-gateway VM using kvm_provision role

- name: Render gateway cloud-init user-data
  ansible.builtin.template:
    src: gateway-user-data.yaml.j2
    dest: "/tmp/{{ nym_network.gateway.name }}-user-data.yaml"
    mode: "0644"
  become: true
  register: _gw_userdata

- name: Provision nym-gateway VM via kvm_provision
  ansible.builtin.include_role:
    name: kvm_provision
  vars:
    vm_name: "{{ nym_network.gateway.name }}"
    vm_vcpus: "{{ nym_network.gateway.vcpus }}"
    vm_ram_mb: "{{ nym_network.gateway.memory_mb }}"
    vm_net: "{{ nym_network.gateway.external_network }}"
    vm_private_net: "{{ nym_network.libvirt_network_name }}"
    base_image_url: "{{ nym_network.gateway.image_url }}"
    base_image_name: "{{ nym_network.gateway.image_name }}"
    vm_cloud_init_user_data: "/tmp/{{ nym_network.gateway.name }}-user-data.yaml"
```

Notes:
- `vm_private_net` may not be a standard `kvm_provision` var — Task 8 verifies and adds dual-network support if missing.
- `vm_cloud_init_user_data` is the path to the user-data file; assumed that `kvm_provision` builds a cloudinit.iso from it.

- [ ] **Step 2: Inspect `kvm_provision` to confirm the interface**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
grep -nE "vm_cloud_init|cloud-init|private_net|vm_net" roles/kvm_provision/tasks/main.yml roles/kvm_provision/templates/*.j2 | head -20
```

Note which variables `kvm_provision` actually reads. If `vm_cloud_init_user_data` is not recognized, we'll defer to Task 8 or extend that role there.

- [ ] **Step 3: Commit (even if gateway.yml is not yet functional end-to-end)**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/nym_network/tasks/gateway.yml
git commit -m "nym_network: gateway VM task composition"
```

---

### Task 6: Port guestfish client network config templates

**Files:**
- Read: `~/Source_Codes/mein/terraform-kvm/modules/nym-network/scripts/configure-client-network.sh` (source)
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/client-netconfig-eth0.j2`
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/client-resolv.conf.j2`
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/files/test-isolation.sh` (copy verbatim from Terraform sources)

- [ ] **Step 1: Read the Terraform shell script**

```bash
cat ~/Source_Codes/mein/terraform-kvm/modules/nym-network/scripts/configure-client-network.sh
```

Note the embedded config files (systemd-networkd, resolv.conf, sysctl, test-isolation.sh) and their static content vs. variable substitutions.

- [ ] **Step 2: Write `templates/client-netconfig-eth0.j2`**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/client-netconfig-eth0.j2`:

```
[Match]
Name=eth0

[Network]
Address={{ nym_network.client_internal_ip }}/{{ nym_network.internal_cidr.split('/')[1] }}
Gateway={{ nym_network.gateway_internal_ip }}
DNS={{ nym_network.gateway_internal_ip }}
```

- [ ] **Step 3: Write `templates/client-resolv.conf.j2`**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/templates/client-resolv.conf.j2`:

```
nameserver {{ nym_network.gateway_internal_ip }}
```

- [ ] **Step 4: Copy `test-isolation.sh` verbatim**

```bash
cp ~/Source_Codes/mein/terraform-kvm/modules/nym-network/scripts/test-isolation.sh \
   ~/Source_Codes/mein/ansible-playbooks/roles/nym_network/files/test-isolation.sh
chmod 0755 ~/Source_Codes/mein/ansible-playbooks/roles/nym_network/files/test-isolation.sh
```

- [ ] **Step 5: Commit**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/nym_network/templates/client-netconfig-eth0.j2 \
        roles/nym_network/templates/client-resolv.conf.j2 \
        roles/nym_network/files/test-isolation.sh
git commit -m "nym_network: port client network config templates + isolation test"
```

---

### Task 7: Implement guestfish network injection (`tasks/guestfish.yml`)

**Files:**
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/guestfish.yml`

**Reference:** terraform-kvm `modules/nym-network/scripts/configure-client-network.sh`.

- [ ] **Step 1: Write `tasks/guestfish.yml`**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/guestfish.yml`:

```yaml
---
# Inject network config into the Kicksecure client volume via guestfish.
# Called after kvm_provision clones the base image into the client volume.

- name: Render client netconfig to temp
  ansible.builtin.template:
    src: client-netconfig-eth0.j2
    dest: "/tmp/nym-client-10-eth0.network"
    mode: "0644"
  become: true

- name: Render client resolv.conf to temp
  ansible.builtin.template:
    src: client-resolv.conf.j2
    dest: "/tmp/nym-client-resolv.conf"
    mode: "0644"
  become: true

- name: Write sysctl disable-ipv6 to temp
  ansible.builtin.copy:
    content: "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n"
    dest: "/tmp/nym-client-99-disable-ipv6.conf"
    mode: "0644"
  become: true

- name: Copy test-isolation.sh to temp
  ansible.builtin.copy:
    src: test-isolation.sh
    dest: "/tmp/nym-client-test-isolation.sh"
    mode: "0755"
  become: true

- name: Inject network config + test script into Kicksecure volume via guestfish
  ansible.builtin.shell:
    cmd: |
      guestfish --rw -a "{{ libvirt_pool_dir | default('/var/lib/libvirt/images') }}/{{ nym_network.client.image_name }}" <<'EOF'
      run
      mount /dev/sda3 /
      upload /tmp/nym-client-10-eth0.network /etc/systemd/network/10-eth0.network
      ln-sf /lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
      rm-f /etc/systemd/system/NetworkManager.service
      ln-s /dev/null /etc/systemd/system/NetworkManager.service
      rm-f /etc/systemd/system/NetworkManager-dispatcher.service
      ln-s /dev/null /etc/systemd/system/NetworkManager-dispatcher.service
      rm-f /etc/systemd/system/NetworkManager-wait-online.service
      ln-s /dev/null /etc/systemd/system/NetworkManager-wait-online.service
      upload /tmp/nym-client-resolv.conf /etc/resolv.conf
      upload /tmp/nym-client-99-disable-ipv6.conf /etc/sysctl.d/99-disable-ipv6.conf
      upload /tmp/nym-client-test-isolation.sh /opt/test-isolation.sh
      chmod 0755 /opt/test-isolation.sh
      EOF
  become: true
  register: _guestfish_result
  changed_when: "_guestfish_result.rc == 0"
  failed_when:
    - _guestfish_result.rc != 0
    - "'is mounted' not in (_guestfish_result.stderr | default(''))"

- name: Remove temporary files
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - /tmp/nym-client-10-eth0.network
    - /tmp/nym-client-resolv.conf
    - /tmp/nym-client-99-disable-ipv6.conf
    - /tmp/nym-client-test-isolation.sh
  become: true
```

Notes:
- Mount `/dev/sda3` matches the Kicksecure partition layout (per terraform-kvm's script and the 2026-03-01 nym-network report).
- `rm-f` before `ln-s` avoids the `ln-sf /dev/null` bug documented in the 2026-03-01 report (guestfish resolved `/dev/null` to the device node instead of creating a symlink — use `rm-f + ln-s` explicitly).
- The `failed_when` allows the edge case where the image is locked by a running VM (error mentions "is mounted") to surface as a clear failure instead of continuing.

- [ ] **Step 2: Commit**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/nym_network/tasks/guestfish.yml
git commit -m "nym_network: guestfish network injection task"
```

---

### Task 8: Verify `kvm_provision` supports our needs; extend if necessary

**Rationale:** `tasks/gateway.yml` (Task 5) assumes `kvm_provision` accepts `vm_cloud_init_user_data` and `vm_private_net`. Need to confirm.

- [ ] **Step 1: Inspect `kvm_provision` inputs**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
grep -nE "vm_cloud_init|vm_private_net|cloudinit|private_network_name" \
  roles/kvm_provision/tasks/main.yml \
  roles/kvm_provision/templates/*.j2 \
  roles/kvm_provision/defaults/main.yml
```

Note which variables are actually referenced.

- [ ] **Step 2: Decision point — based on output:**

  - **If `vm_cloud_init_user_data` is already wired:** skip to Step 4.
  - **If not:** add cloud-init ISO generation to `kvm_provision/tasks/main.yml`. Add these tasks after pool creation and before VM definition:

    ```yaml
    - name: Create cloud-init ISO from user-data
      ansible.builtin.command:
        cmd: >
          genisoimage -output {{ libvirt_pool_dir }}/{{ vm_name }}-cidata.iso
          -volid cidata -joliet -rock {{ vm_cloud_init_user_data }}
        creates: "{{ libvirt_pool_dir }}/{{ vm_name }}-cidata.iso"
      when: vm_cloud_init_user_data is defined and vm_cloud_init_user_data | length > 0
      become: true
    ```

    Then update `roles/kvm_provision/templates/vm-template.xml.j2` to conditionally include a second disk for the cidata ISO when `vm_cloud_init_user_data` is defined.

  - **If `vm_private_net` / dual-NIC support is missing:** update `vm-template.xml.j2` to conditionally add a second `<interface>` block when `vm_private_net` is defined:

    ```xml
    {% if vm_private_net is defined and vm_private_net | length > 0 %}
    <interface type='network'>
      <source network='{{ vm_private_net }}'/>
      <model type='virtio'/>
    </interface>
    {% endif %}
    ```

- [ ] **Step 3: Test the `kvm_provision` changes in isolation (if you modified it)**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
ansible-playbook --check --diff --syntax-check -i hosts.yml playbooks/nym-network.yml 2>&1 | head -20
```

Expected: no syntax errors. (This will fail with undefined playbook — Task 10 creates it. Just confirm role syntax.)

Alternative syntax check:
```bash
ansible localhost -m include_role -a "name=kvm_provision" --check 2>&1 | head
```

- [ ] **Step 4: Commit kvm_provision changes if any**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/kvm_provision/
git diff --cached --stat
git commit -m "kvm_provision: add cloud-init user-data + private network support"
```

(If you didn't modify `kvm_provision`, skip the commit.)

---

### Task 9: Implement client VM provisioning (`tasks/client.yml`)

**Files:**
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/client.yml`

**Key difference vs. gateway:** Kicksecure has no cloud-init. We clone the base image, run guestfish injection, then define the domain. No cloudinit.iso.

- [ ] **Step 1: Write client.yml**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/client.yml`:

```yaml
---
# Provision nym-client VM (Kicksecure, no cloud-init)
# Sequence: clone base → inject network config via guestfish → define + start domain

- name: Ensure Kicksecure base image exists on this host
  ansible.builtin.stat:
    path: "{{ nym_network.client.base_image_path }}"
  register: _kicksecure_base

- name: Fail if Kicksecure base image missing
  ansible.builtin.fail:
    msg: >-
      Kicksecure base image not found at {{ nym_network.client.base_image_path }}.
      Build it first via terraform-kvm/images/build-kicksecure-client.sh, or override
      `nym_network.client.base_image_path`.
  when: not _kicksecure_base.stat.exists

- name: Clone Kicksecure base image to client volume
  ansible.builtin.copy:
    src: "{{ nym_network.client.base_image_path }}"
    dest: "{{ libvirt_pool_dir | default('/var/lib/libvirt/images') }}/{{ nym_network.client.image_name }}"
    remote_src: true
    force: false   # don't overwrite if client volume exists
    owner: libvirt-qemu
    group: kvm
    mode: "0600"
  become: true

- name: Inject network config via guestfish
  ansible.builtin.include_tasks: guestfish.yml

- name: Undefine any stale nym-client domain
  community.libvirt.virt:
    command: undefine
    name: "{{ nym_network.client.name }}"
    flags:
      - nvram
  failed_when: false

- name: Define nym-client domain via kvm_provision template
  ansible.builtin.include_role:
    name: kvm_provision
  vars:
    vm_name: "{{ nym_network.client.name }}"
    vm_vcpus: "{{ nym_network.client.vcpus }}"
    vm_ram_mb: "{{ nym_network.client.memory_mb }}"
    vm_net: "{{ nym_network.libvirt_network_name }}"   # PRIMARY interface: internal only (no NAT)
    vm_cloud_init_user_data: ""                         # Kicksecure has no cloud-init
    base_image_url: ""                                  # don't download; we cloned
    base_image_name: "{{ nym_network.client.image_name }}"
```

Notes:
- `force: false` on the copy means re-runs skip if the client volume already exists. For a full rebuild, run the destroy playbook first.
- `vm_net` uses the internal network as the primary (and only) interface — the client has no external network by design.

- [ ] **Step 2: Commit**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/nym_network/tasks/client.yml
git commit -m "nym_network: client VM task (clone + guestfish + define)"
```

---

### Task 10: Implement destroy task (`tasks/destroy.yml`)

**Files:**
- Create: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/destroy.yml`
- Modify: `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/main.yml` (add tagged include)

- [ ] **Step 1: Write destroy.yml**

Create `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/destroy.yml`:

```yaml
---
# Tear down nym-network resources. Idempotent — safe to run against partial state.

- name: Stop nym-gateway domain
  community.libvirt.virt:
    command: destroy
    name: "{{ nym_network.gateway.name }}"
  failed_when: false

- name: Undefine nym-gateway domain (with NVRAM)
  community.libvirt.virt:
    command: undefine
    name: "{{ nym_network.gateway.name }}"
    flags:
      - nvram
  failed_when: false

- name: Stop nym-client domain
  community.libvirt.virt:
    command: destroy
    name: "{{ nym_network.client.name }}"
  failed_when: false

- name: Undefine nym-client domain (with NVRAM)
  community.libvirt.virt:
    command: undefine
    name: "{{ nym_network.client.name }}"
    flags:
      - nvram
  failed_when: false

- name: Remove VM volumes
  ansible.builtin.file:
    path: "{{ libvirt_pool_dir | default('/var/lib/libvirt/images') }}/{{ item }}"
    state: absent
  loop:
    - "{{ nym_network.gateway.image_name }}"
    - "{{ nym_network.gateway.name }}-cidata.iso"
    - "{{ nym_network.client.image_name }}"
  become: true

- name: Stop nym libvirt network
  community.libvirt.virt_net:
    command: destroy
    name: "{{ nym_network.libvirt_network_name }}"
  failed_when: false

- name: Undefine nym libvirt network
  community.libvirt.virt_net:
    command: undefine
    name: "{{ nym_network.libvirt_network_name }}"
  failed_when: false
```

- [ ] **Step 2: Update `tasks/main.yml` to add `never,destroy` tagged include**

Edit `~/Source_Codes/mein/ansible-playbooks/roles/nym_network/tasks/main.yml`; append at the end:

```yaml

- name: Destroy nym-network (tagged; never runs by default)
  ansible.builtin.include_tasks: destroy.yml
  tags:
    - never
    - destroy
```

- [ ] **Step 3: Commit**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add roles/nym_network/tasks/destroy.yml roles/nym_network/tasks/main.yml
git commit -m "nym_network: destroy task + main.yml integration"
```

---

### Task 11: Write orchestration playbook `playbooks/nym-network.yml`

**Files:**
- Create: `~/Source_Codes/mein/ansible-playbooks/playbooks/nym-network.yml`

- [ ] **Step 1: Write the playbook**

Create `~/Source_Codes/mein/ansible-playbooks/playbooks/nym-network.yml`:

```yaml
---
# Provision the NymVPN gateway + Kicksecure client VMs on pc-do-b.
#
# Usage:
#   CONFIG_STORE=../prod-values ansible-playbook -i hosts.yml playbooks/nym-network.yml
#
# Destroy:
#   ansible-playbook -i hosts.yml playbooks/nym-network.yml --tags destroy

- name: Provision nym-network
  hosts: pc-do-b
  become: true
  gather_facts: true

  roles:
    - role: config_loader
      vars:
        config_store_path: "{{ lookup('env', 'CONFIG_STORE') | default('', true) }}"
        config_environment: production

    - role: nym_network
```

- [ ] **Step 2: Syntax-check**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
ansible-playbook -i hosts.yml playbooks/nym-network.yml --syntax-check
```

Expected output: `playbook: playbooks/nym-network.yml` (no errors).

- [ ] **Step 3: Commit**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git add playbooks/nym-network.yml
git commit -m "nym_network: orchestration playbook"
```

---

### Task 12: Dry-run playbook, fix any rendering or variable errors

- [ ] **Step 1: Dry-run against pc-do-b**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
CONFIG_STORE=../prod-values ansible-playbook -i hosts.yml playbooks/nym-network.yml --check --diff 2>&1 | tee /tmp/nym-dry-run.log
tail -50 /tmp/nym-dry-run.log
```

Expected:
- No `undefined variable` errors.
- `--diff` output shows what would change.
- Tasks that need to `run` (not check) may show as errors in `--check` mode — note them but don't treat as blockers.

- [ ] **Step 2: Fix any template errors inline**

For each error:
- Missing variable → check `roles/nym_network/defaults/main.yml` and `prod-values/production/pc-do-b/values.yaml`. If both are set correctly, verify `config_loader` ran first.
- Jinja2 syntax error → edit the template.
- Task-level failure → review the specific task.

Commit fixes per logical unit:

```bash
git add -p
git commit -m "nym_network: fix <specific issue>"
```

- [ ] **Step 3: Re-run dry-run until clean**

Repeat Step 1. Proceed when `--check --diff` reports cleanly.

---

### Task 13: First real deploy — destroy existing Terraform-deployed nym VMs, run playbook

**Rationale:** pc-do-b currently has the Terraform-deployed nym-gateway (with cache of `nym-client` image, nym-client VM definition). Must clear those first so Ansible owns the definitions cleanly.

- [ ] **Step 1: Destroy existing Terraform state**

```bash
ssh pc-do-b 'sudo virsh list --all | grep nym; sudo virsh net-list --all | grep nym'
```

Then cleanup:

```bash
ssh pc-do-b 'sudo virsh destroy nym-gateway 2>/dev/null; sudo virsh undefine nym-gateway --nvram 2>/dev/null; sudo virsh destroy nym-client 2>/dev/null; sudo virsh undefine nym-client --nvram 2>/dev/null; sudo virsh net-destroy nym-network 2>/dev/null; sudo virsh net-undefine nym-network 2>/dev/null; echo cleanup-done'
```

Also remove stale disk images (these get re-created by the Ansible role):

```bash
ssh pc-do-b 'sudo rm -vf /var/lib/libvirt/images/nym-gateway*.qcow2 /var/lib/libvirt/images/nym-gateway-cloudinit.iso /var/lib/libvirt/images/nym-client.qcow2; ls /var/lib/libvirt/images/ | grep nym || echo "no nym files"'
```

- [ ] **Step 2: Ensure Kicksecure base image exists on pc-do-b**

```bash
ssh pc-do-b 'ls -la /var/lib/libvirt/images/kicksecure-client-base.qcow2'
```

If missing, transfer it from wherever it lives (per the 2026-03-01 report, it was built on pc-do-b via `images/build-kicksecure-client.sh`). This plan does NOT automate the base image build.

- [ ] **Step 3: Run the playbook for real**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
CONFIG_STORE=../prod-values ansible-playbook -i hosts.yml playbooks/nym-network.yml 2>&1 | tee /tmp/nym-deploy.log
```

Expected: all tasks succeed, final PLAY RECAP shows 0 failed.

- [ ] **Step 4: Verify end-state**

```bash
ssh pc-do-b 'sudo virsh list; sudo virsh net-list'
```

Expected:
- `nym-gateway` and `nym-client` both `running`.
- `nym-network` active.

Then VM-level checks:

```bash
# SPICE available on gateway
ssh pc-do-b 'sudo virsh domdisplay nym-gateway'

# Client boots (check state)
ssh pc-do-b 'sudo virsh domstate nym-client'
```

Wait 60 seconds for both VMs to fully boot, then run the isolation test:

```bash
# From pc-do-b, SSH to gateway, then curl 8.8.8.8 to prove mixnet path works
# (gateway external IP is on default libvirt NAT, find via domifaddr)
ssh pc-do-b 'sudo virsh domifaddr nym-gateway'
```

- [ ] **Step 5: If deploy succeeds, document and commit any fixups**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
git status
# If fixes were needed during the deploy, commit them:
git add -p
git commit -m "nym_network: <fixups from first deploy>"
```

---

### Task 14: Round-trip test — destroy and redeploy via Ansible

- [ ] **Step 1: Destroy via Ansible**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
CONFIG_STORE=../prod-values ansible-playbook -i hosts.yml playbooks/nym-network.yml --tags destroy 2>&1 | tail -20
```

Verify:

```bash
ssh pc-do-b 'sudo virsh list --all | grep nym; sudo virsh net-list --all | grep nym; ls /var/lib/libvirt/images/ | grep nym'
```

Expected: no matches (empty output).

- [ ] **Step 2: Redeploy**

```bash
cd ~/Source_Codes/mein/ansible-playbooks
CONFIG_STORE=../prod-values ansible-playbook -i hosts.yml playbooks/nym-network.yml 2>&1 | tail -30
```

Expected: clean success, all tasks pass.

- [ ] **Step 3: Re-run (no-op idempotency check)**

```bash
CONFIG_STORE=../prod-values ansible-playbook -i hosts.yml playbooks/nym-network.yml 2>&1 | grep -E "ok=|changed=|failed=" | tail -5
```

Expected: PLAY RECAP shows `changed=0` or near-zero (libvirt facts gathering may report "changed" even when nothing changes — that's OK). Zero failed.

---

### Task 15: Retire the Terraform module

**Only execute after Task 14 passes.**

**Files:**
- Delete: `~/Source_Codes/mein/terraform-kvm/modules/nym-network/`
- Delete: `~/Source_Codes/mein/terraform-kvm/environments/pc-do-b/` (environment only existed to instantiate nym-network)
- Modify: `~/Source_Codes/mein/terraform-kvm/main.tf` if it references nym-network
- Modify: `~/Source_Codes/mein/terraform-kvm/CLAUDE.md` and `README.md` — note the migration

- [ ] **Step 1: Archive the module source via git (don't blind-delete)**

```bash
cd ~/Source_Codes/mein/terraform-kvm
git mv modules/nym-network modules/.archived-nym-network
git mv environments/pc-do-b environments/.archived-pc-do-b
```

- [ ] **Step 2: Add a migration note in README**

Edit `~/Source_Codes/mein/terraform-kvm/README.md` — add a section:

```markdown
## Migrated modules

- **nym-network** (archived 2026-04-19) — replaced by Ansible role at
  `ansible-playbooks/roles/nym_network/`. Driving playbook:
  `playbooks/nym-network.yml`. See
  `ansible-playbooks/docs/plans/2026-04-19-nym-network-ansible-design.md`.
```

- [ ] **Step 3: Commit**

```bash
cd ~/Source_Codes/mein/terraform-kvm
git add -A
git commit -m "chore: archive nym-network module (migrated to Ansible role)"
```

- [ ] **Step 4: Document in tech-docs vault**

Create `~/Documents/tech-docs/03-reports/2026-04-19-nym-network-ansible-migration-report.md` summarizing:

- What was ported, what stayed as Terraform
- Problems encountered during migration
- Round-trip verification results
- Commands for future reference

Use the report template from `~/Documents/tech-docs/templates/report.md`.

```bash
cd ~/Documents/tech-docs
git add 03-reports/2026-04-19-nym-network-ansible-migration-report.md
git commit -m "docs: add nym-network Ansible migration report"
```

---

## Self-Review checklist

Before marking this plan complete, verify:

- [ ] Every step has concrete code or concrete commands — no "implement similar to above" / "TBD" / "handle edge cases".
- [ ] File paths are absolute (`~/Source_Codes/...`).
- [ ] Each task is committable on its own (even if not yet end-to-end functional).
- [ ] The data flow from config_loader → role defaults → prod-values values.yaml → rendered templates is traceable.
- [ ] Destroy path covers every resource the create path creates.
- [ ] Terraform module is only archived (not hard-deleted) so we can reference it if something goes wrong.
