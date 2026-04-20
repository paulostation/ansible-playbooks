# nym-network Ansible Role Design

**Date:** 2026-04-19
**Status:** Proposed
**Replaces:** `terraform-kvm/modules/nym-network/` Terraform module

## Problem

The `nym-network` Terraform module (368 lines of HCL) provisions a 2-VM setup on pc-do-b:
- **nym-gateway** (Ubuntu 24.04) running `nym-vpnd` for mixnet egress
- **nym-client** (Kicksecure 18) isolated, routing through the gateway

The libvirt Terraform provider (`dmacvicar/libvirt` v0.9.1+) has structural issues that forced multiple workarounds:

- `<graphics>` element silently dropped on apply → post-deploy `virsh edit` required
- No good way to manage `<sound>`, `<video>`, NVRAM devices
- `null_resource` + `remote-exec` provisioners used for guestfish injection (anti-pattern)
- `lifecycle { ignore_changes = [devices] }` papers over state drift

These aren't improving upstream and have blocked iteration. Ansible's `community.libvirt` collection with Jinja2 XML templates gives full fidelity and composes naturally with the existing `kvm_provision` role already in `ansible-playbooks`.

## Goals

- Replace `nym-network` Terraform module with an Ansible role that provisions the same 2-VM setup on pc-do-b.
- Reuse the existing `kvm_provision` role for generic VM lifecycle; add only nym-specific orchestration.
- Consume configuration from `prod-values` git repo via the existing `config_loader` role (same pattern as stremio-rpi, vpn-hub, etc.).
- Operate idempotently on re-runs; provide a `--tags destroy` path for teardown.

## Non-Goals (v1)

- Migrating `isolated-network`, `lokinet-network`, or `standalone-vm` modules (scope B from brainstorm).
- Ansible-managed Kicksecure base image builds — `images/build-kicksecure-client.sh` stays a manual/separate step.
- Secrets introduction — the current module has no secrets today.
- Multi-hypervisor deployment — v1 targets pc-do-b only. Adding another host becomes an inventory entry change.

## Pre-Implementation Cleanup (Step 0)

The existing inventory contains a stale `omarchy-pc-do-b` entry:

- `ansible-playbooks/hosts.yml` has `omarchy-pc-do-b:` under `home` group
- `prod-values/production/omarchy-pc-do-b/ansible.sops.yaml` contains placeholder data (wireguard IP `100.64.7.7` which is actually ipad, copy-paste content)
- `prod-values/values.yaml` `vpn.peers` list references `{ name: omarchy-pc-do-b, ip: "100.64.7.7" }`
- `prod-values/production/secrets.sops.yaml` has an encrypted entry keyed `omarchy-pc-do-b`

The actual hypervisor is `pc-do-b` (tailscale name, `100.64.7.6`, LAN `192.168.15.106`). User preference: inventory names match tailscale names.

**Cleanup tasks:**

1. Remove `omarchy-pc-do-b` stub directory from `prod-values/production/`
2. Remove `omarchy-pc-do-b` entries from `prod-values/values.yaml` and `prod-values/production/secrets.sops.yaml`
3. Rename `omarchy-pc-do-b` to `pc-do-b` in `ansible-playbooks/hosts.yml`, add `ansible_host: pc-do-b.ts.paulo.software.vpn` (tailnet resolution)
4. Create `prod-values/production/pc-do-b/values.yaml` with `nym_network:` block
5. Update docs in `ansible-playbooks/docs/plans/2026-01-16-secrets-restructure*.md` if still active references (likely historical record, leave as-is)

## Architecture

```
ansible-playbooks/
├── hosts.yml                          MODIFIED (rename host)
├── playbooks/
│   └── nym-network.yml                NEW — orchestration playbook
├── roles/
│   ├── config_loader/                 EXISTING — loads prod-values YAML
│   ├── kvm_provision/                 EXISTING — pool/volume/domain
│   └── nym_network/                   NEW — this design
│       ├── defaults/main.yml
│       ├── meta/main.yml              (empty or role deps)
│       ├── tasks/
│       │   ├── main.yml               dispatcher
│       │   ├── network.yml            libvirt network def
│       │   ├── gateway.yml            gateway VM
│       │   ├── client.yml             client VM
│       │   ├── guestfish.yml          Kicksecure config injection
│       │   └── destroy.yml            tagged `never,destroy`
│       └── templates/
│           ├── libvirt-nym-network.xml.j2
│           ├── gateway-user-data.yaml.j2
│           ├── client-netconfig-eth0.j2
│           └── client-resolv.conf.j2

prod-values/production/pc-do-b/
├── values.yaml                        NEW — nym_network: block
└── ansible.sops.yaml                  (not needed v1)
```

## Components

### `config_loader` (existing, unchanged)

Loads `prod-values` via `include_vars` 5-tier stack. nym-network values live under `nym_network:` key in `prod-values/production/pc-do-b/values.yaml`:

```yaml
nym_network:
  libvirt_network_name: nym-network
  internal_cidr: 10.55.0.0/24
  gateway_internal_ip: 10.55.0.1
  client_internal_ip: 10.55.0.10
  gateway:
    vcpu: 2
    memory_mb: 2048
    image_url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    hostname: nym-gateway
  client:
    vcpu: 2
    memory_mb: 4096
    base_image_path: "/var/lib/libvirt/images/kicksecure-client-base.qcow2"
    hostname: nym-client
  dns_upstream: "1.1.1.1"
```

### `kvm_provision` (existing, unchanged)

Called by `nym_network` tasks via `include_role` with per-VM variables. Creates storage pool, downloads/clones base image as volume, generates cloud-init ISO (if applicable), defines domain XML via `vm-template.xml.j2`, starts the VM.

### `nym_network` (new)

Five task files:

- **`network.yml`** — uses `community.libvirt.virt_net` with `libvirt-nym-network.xml.j2` rendered from the CIDR variable. Idempotent: `state: present` for definition, `state: active` for start, `autostart: yes`.

- **`gateway.yml`** — renders `gateway-user-data.yaml.j2` (nym-vpnd install, nftables rules, IP forwarding), then `include_role: kvm_provision` with `vm_name: nym-gateway`, `vm_cloud_init_user_data: "{{ rendered_userdata_path }}"`, `vm_networks: [default, nym-network]`.

- **`client.yml`** — no cloud-init (Kicksecure has none). Uses `include_role: kvm_provision` to clone base image into a client volume, then calls `guestfish.yml`, then defines domain XML via kvm_provision with `vm_cloud_init_user_data: ""` to skip the ISO.

- **`guestfish.yml`** — runs `guestfish` against the client volume to inject:
  - `/etc/systemd/network/10-eth0.network` (static IP, gateway = `gateway_internal_ip`)
  - `/etc/resolv.conf` (DNS via gateway)
  - `/etc/sysctl.d/99-disable-ipv6.conf`
  - NetworkManager masked via `/dev/null` symlinks
  - `/opt/test-isolation.sh` script
  Uses `ansible.builtin.command` with `changed_when` detection (template hash diff). Prereq task in `main.yml` ensures `libguestfs-tools` is installed via `ansible.builtin.apt` (idempotent).

- **`destroy.yml`** — tagged `never,destroy`. Stops and undefines both VMs, deletes volumes, stops and undefines network. `ansible-playbook playbooks/nym-network.yml --tags destroy`.

### Playbook `nym-network.yml`

```yaml
- hosts: pc-do-b
  become: yes
  roles:
    - role: config_loader
      vars:
        config_store_path: "{{ lookup('env', 'CONFIG_STORE') | default('', true) }}"
        config_environment: production
    - role: nym_network
```

## Data Flow

```
User runs: CONFIG_STORE=../prod-values ansible-playbook playbooks/nym-network.yml
                                        │
                                        ▼
        ┌─────────────────────────────────────────────────────────┐
        │ Controller (omarchy-mouse typically)                    │
        │  - SOPS decrypts *.sops.yaml from prod-values           │
        │  - include_vars loads 5-tier stack into facts           │
        └─────────────────────────────────────────────────────────┘
                                        │
                                        ▼  SSH to pc-do-b
        ┌─────────────────────────────────────────────────────────┐
        │ pc-do-b (Ubuntu server, 192.168.15.106)                 │
        │                                                          │
        │  1. network.yml   → virt_net defines nym-network        │
        │                     (virbr-nym, 10.55.0.0/24)            │
        │                                                          │
        │  2. gateway.yml   → render user-data.yaml                │
        │                   → include_role kvm_provision           │
        │                       • download Ubuntu cloud image     │
        │                       • create gateway volume            │
        │                       • create cloud-init ISO            │
        │                       • define + start domain            │
        │                                                          │
        │  3. client.yml    → include_role kvm_provision (volume) │
        │                   → guestfish.yml (inject configs)      │
        │                   → include_role kvm_provision (domain) │
        │                   → start client domain                 │
        │                                                          │
        │  Result: 2 VMs running, client routes through gateway   │
        └─────────────────────────────────────────────────────────┘
```

## Error Handling

**Playbook-level:**
- `config_loader` wraps optional file loads in `failed_when: false` (existing pattern). Missing tier files aren't fatal; role defaults fill gaps.
- `nym_network` defaults provide sane fallbacks so the role runs without prod-values if needed.

**Task-level:**
- `community.libvirt.virt_net` is idempotent. If XML differs from defined, guarded `state: absent + present` block with `when: force_recreate | default(false)` prevents accidental re-creation that disconnects running VMs.
- `ansible.builtin.get_url` uses `checksum:` when known, `force: no` to avoid re-download.
- Guestfish injection wrapped in `block: + rescue:` — guestfish ops are atomic per-command; partial runs leave usable volumes. Exit code checked explicitly (guestfish sometimes returns 0 on silent failure).
- `community.libvirt.virt state: running` retries transient failures and creates the domain from defined XML if missing.
- Post-deploy SPICE XML edit eliminated: our Jinja2 `vm-template.xml.j2` renders the `<graphics>`, `<video>`, and `<sound>` elements directly, so the Terraform-era virsh-edit workaround is not needed.

**Runtime failures:**
- VM fails to boot → role continues; `wait_for_connection` timeout or `virsh domstate` check surfaces it. Debug via `virsh console`.
- Gateway nym-vpnd provisioning fails → cloud-init logs surfaceable via `virsh console` + end-of-playbook cloud-init status check. Doesn't poison client provisioning; client just lacks egress until gateway is fixed.

**Destroy path:**
- All removal tasks use `failed_when: false`. Safe to run against partial states.
- Order: stop domains → undefine domains → remove volumes → stop network → undefine network.

## Testing

- **Syntax:** `ansible-playbook playbooks/nym-network.yml --syntax-check`
- **Dry run:** `ansible-playbook playbooks/nym-network.yml --check --diff`
- **Post-deploy verification** (tagged `verify`): virt_net active, both VMs running, `wait_for` TCP 22 on gateway external IP, `/opt/test-isolation.sh` run inside client via SSH jump through gateway.
- **Destroy round-trip:** destroy → `virsh list --all | grep nym-` empty → re-run create → full deployment works.
- **Manual checklist** (in role README): playbook exits clean, both VMs running, client DNS via gateway (`resolvectl status` shows 10.55.0.1), 8.8.8.8 reachable from client (via mixnet), 192.168.15.0/24 hosts unreachable from client, `nym-vpnc status` on gateway shows anonymous mode active.

## Migration Steps (Summary)

1. **Cleanup** (Step 0 above) — rename `omarchy-pc-do-b` → `pc-do-b` across `hosts.yml`, prod-values.
2. **Create `prod-values/production/pc-do-b/values.yaml`** with `nym_network:` block.
3. **Create `roles/nym_network/`** — defaults, tasks, templates per architecture above.
4. **Create `playbooks/nym-network.yml`** — orchestrator.
5. **Test on clean pc-do-b** — destroy any existing nym VMs first (`sudo virsh destroy nym-gateway; sudo virsh undefine nym-gateway`; same for client; `sudo virsh net-destroy nym-network; sudo virsh net-undefine nym-network`), then run the playbook.
6. **Verify** — manual checklist.
7. **Retire Terraform module** — once playbook is proven, delete `terraform-kvm/modules/nym-network/` and `terraform-kvm/environments/pc-do-b/` (the env only instantiates nym-network). Commit with message referencing this design doc.

## Related

- [[2026-02-07-config-store-consolidation-report]] — config_loader pattern
- [[2026-01-16-secrets-restructure-design]] — hosts.yml + SOPS structure
- [[2026-04-18-ceph-squid-rebuild-report]] — current pc-do-b state
- [[2026-03-01-nym-network-kicksecure-redeploy-report]] — current nym-network Terraform deployment
