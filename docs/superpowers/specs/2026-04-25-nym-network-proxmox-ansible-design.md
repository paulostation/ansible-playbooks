# `nym_network` on Proxmox via Ansible — Design

**Date:** 2026-04-25
**Status:** Design draft; awaiting user review
**Author:** Paulo Francisco (with Claude)
**Branch:** `feat/nym-network-proxmox` (worktree at `.worktrees/nym-network-proxmox/`)
**Base:** `feat/nym-network-ansible`
**Related:**
- `terraform-kvm/docs/superpowers/specs/2026-04-23-nym-network-proxmox-module-design.md` (the abandoned Terraform path)
- `tech-docs/03-reports/2026-04-20-nym-network-ansible-migration-report.md` (the libvirt → Ansible migration that established the pattern this design extends)

## Summary

Extend the existing `nym_network` Ansible role (today: libvirt-only) to support deploying the Nym gateway + Kicksecure client VMs to a Proxmox VE 9 host. Add a sibling `proxmox_provision` role mirroring `kvm_provision`. Backend selection is a single var (`nym_network.provision_backend = libvirt | proxmox`). Auth is SSH-only as root to the Proxmox host; VM lifecycle uses idempotent `qm`/`pvesh` invocations rather than the Proxmox API. Image management on the Proxmox host is checksum-gated and self-healing — re-runs only download when missing or stale. S3-hosted images are presigned on the control host using a per-image `aws_profile`.

This is a deliberate retreat from the Terraform/bpg path explored in `terraform-kvm`, which accumulated friction (provider ACLs, presigned URL HEAD failures, SDN two-phase apply edge cases, cluster-aware SSH IP resolution) without proportional benefit for a 2-VM deploy.

## Goals

1. Deploy the same Nym gateway + Kicksecure client architecture to Proxmox VE 9 that the libvirt path delivers today.
2. Reuse the existing `nym_network` role's content (cloud-init template, secrets, kill-switch design, network injection logic for the client).
3. Provisioning backend selectable per-host via a single var; libvirt path remains untouched.
4. Single auth surface: SSH key as root on the Proxmox host. No Proxmox API token. No bespoke ACL role.
5. Image management on Proxmox is idempotent and self-healing — checksum-gated, downloads only on miss/mismatch.
6. S3 presigning happens on the control host using `aws s3 presign --profile <profile>` per-image.
7. Preflight failures are loud and actionable (AWS SSO expired, SSH unreachable).

## Non-goals

- No Proxmox API token authentication. SSH-as-root only.
- No `community.general.proxmox_kvm` module use — the collection's `proxmox_kvm` cannot do `importdisk`/disk attach/cicustom attach, so going hybrid (API for create, SSH for attach) doubles the auth surface for negligible value. Pure SSH+qm wins.
- No Terraform retention. The `terraform-kvm` Proxmox module stays in that repo as a documented escape hatch but is not invoked.
- No high availability, multi-node Proxmox, or stretch clustering.
- No Proxmox firewall rules at node/datacenter level — the kill switch lives in the gateway VM's nftables, same as today.
- No support for both Nym AND Lokinet in this iteration. This design covers Nym only; the same `proxmox_provision` role can be reused later for a Lokinet port.
- No automated integration testing. Smoke testing remains manual against the live Proxmox host.

## Background / current state

### Existing libvirt path

The `nym_network` role on `feat/nym-network-ansible` provisions a Nym gateway (Ubuntu cloud image + cloud-init) and a Kicksecure client (golden qcow2 with networking injected via guestfish at deploy time) onto a libvirt host (`pc-do-b`). It uses `kvm_provision` as a sibling role for the libvirt-specific bits (`virt` modules, libvirt domain XML, qcow2 download).

Key separation that this design preserves:
- **`nym_network`** owns Nym-specific content (cloud-init template with NymVPN install + nftables kill switch, network injection script, secrets like `nym_vpn_mnemonic`, the `gateway` and `client` variable structure).
- **`kvm_provision`** owns libvirt mechanics (qcow2 download, libvirt network XML, libvirt domain XML, volume cloning).

### Proxmox target

Per `terraform-kvm/CLAUDE.md` and `tech-docs/01-cheatsheets/proxmox.md`:
- Host `proxmox` at LAN `192.168.15.106`, tailnet `100.64.7.8`, FQDN `proxmox.ts.paulo.software.vpn`.
- PVE 9 (Debian trixie) on the rebuilt pc-do-b box.
- Ceph Squid 19.2.3 integrated via `pveceph`. `ceph-vms` datastore = Ceph pool `vms`.
- `local` datastore (LVM dir on `pve-root`) holds ISOs, snippets, templates.
- SDN enabled by default. `local` already has snippets content type enabled (set during the abandoned Terraform attempt).
- Existing VMs use IDs 100–102; this role defaults to gateway=200, client=201.

### Why this design now

The Terraform/bpg attempt failed for cumulative friction reasons documented in `terraform-kvm/docs/superpowers/specs/2026-04-23-nym-network-proxmox-module-design.md`. Each issue was independently fixable but combined to make a 5-minute manual deploy take days. Same reasoning that drove the libvirt → Ansible migration applies here.

## Architecture

```
playbooks/nym-network.yml            (existing; targets pc-do-b for libvirt path)
playbooks/nym-network-proxmox.yml    (NEW; targets localhost, delegates to proxmox via SSH)

roles/nym_network/                   (existing; extended)
├── defaults/main.yml                (+ provision_backend var, + proxmox.* sub-block)
├── tasks/
│   ├── main.yml                     (extend: dispatch by provision_backend)
│   ├── network.yml                  (libvirt-only path; unchanged)
│   ├── network-proxmox.yml          (NEW: SDN zone + vnet + apply via pvesh)
│   ├── gateway.yml                  (extend: dispatch include_role to libvirt or proxmox provisioner)
│   ├── client.yml                   (extend: dispatch include_role; no guestfish on Proxmox path)
│   └── destroy.yml                  (extend: handle proxmox VMs too)
├── templates/
│   └── (existing templates — gateway-user-data.yaml.j2 reused on both backends)
└── files/

roles/proxmox_provision/             (NEW; sibling of kvm_provision)
├── defaults/main.yml
├── meta/main.yml
├── README.md
└── tasks/
    ├── main.yml                     (orchestrator: preflight → ensure_image → snippets → vm)
    ├── preflight.yml                (verify AWS SSO + SSH-as-root reach)
    ├── ensure_image.yml             (per-image: stat → presign → download)
    ├── snippets.yml                 (upload cicustom YAMLs via SSH copy)
    ├── vm.yml                       (qm create + importdisk + set + start)
    └── destroy.yml                  (qm stop + qm destroy --purge)
```

### Topology

```
              LAN 192.168.15.0/24 (Proxmox node attached via vmbr0)
                          │
              ┌───────────┴────────────────────┐
              │ nym-gateway (vmid 200)         │ net0 → vmbr0   (DHCP, LAN)
              │ Ubuntu cloud image             │ net1 → nymiso  (10.55.0.1/24)
              │ cloud-init: nym-vpn-cli +      │
              │   nftables kill switch +       │
              │   dnsmasq                      │
              └───────────┬────────────────────┘
                          │
                  SDN vnet `nymiso`
                  (zone `nymz`, simple, no VLAN, no uplink)
                          │
              ┌───────────┴────────────────────┐
              │ nym-client (vmid 201)          │ net0 → nymiso (10.55.0.10/24)
              │ Kicksecure golden qcow2        │
              │ (network config baked in)      │
              └────────────────────────────────┘

VM disks → ceph-vms (RBD pool `vms`)
Cloud-init snippets → local:snippets/  (uploaded via SSH copy)
Base images → local:iso/  (downloaded via get_url, checksum-gated)
```

### Backend dispatch

A single var, with a single dispatch site per concept (network / gateway / client / destroy):

```yaml
# nym_network/defaults/main.yml
nym_network:
  provision_backend: libvirt    # "libvirt" | "proxmox"
  # ... existing keys unchanged ...
  proxmox:
    sdn_zone: nymz              # ≤ 8 chars, alphanumeric only (Proxmox SDN constraint)
    sdn_vnet: nymiso            # ≤ 8 chars, alphanumeric only
    external_bridge: vmbr0      # gateway's net0 (LAN/WAN)
    images:
      gateway:
        kind: http
        url: "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
        filename: "jammy-server-cloudimg-amd64.img"
        sha256: "<pinned-from-SHA256SUMS>"
      client:
        kind: s3
        bucket: paulao-vm-images
        key: kicksecure-client-base.qcow2
        aws_profile: personal-admin-management
        presign_expires: 3600
        filename: "kicksecure-nym-client.qcow2"
        sha256: "<computed-from-on-disk-image>"
```

Dispatch sites use `when: nym_network.provision_backend == "<value>"` on `include_tasks` / `include_role` calls.

### `proxmox_provision` role contract

Inputs (passed by `nym_network`):
- `vm_name`, `vm_role` (gateway/client), `vmid`
- `vm_vcpus`, `vm_ram_mb`, `vm_disk_size`
- `vm_net` (external bridge name), `vm_internal_net` (SDN vnet name; gateway only)
- `vm_cloud_init_user_data`, `vm_cloud_init_network_data` (paths on control host; empty for client)
- `base_image_filename`

Role-level vars (`proxmox_provision/defaults/main.yml`):

```yaml
proxmox_provision:
  ssh:
    host: "proxmox.ts.paulo.software.vpn"
    user: "root"
    snippets_path: "/var/lib/vz/snippets"
  storage:
    iso: "local"
    snippets: "local"
    vm_disk: "ceph-vms"
  vmid_pool_start: 200
  images: {}    # populated by nym_network role
```

### Auth model

Single auth surface: **SSH key as root** to the Proxmox host. The role uses `delegate_to: "{{ proxmox_provision.ssh.user }}@{{ proxmox_provision.ssh.host }}"` for all Proxmox-side operations. The control host's `~/.ssh/config` and ssh-agent provide the credential.

`aws sso login --profile <profile>` is a separate prerequisite for any S3-kind images. The role checks this in preflight and fails with the AWS CLI's own error message (which contains the fix hint).

No Proxmox API tokens. No custom ACL roles on Proxmox. No collection-specific dependencies beyond `community.libvirt` (used only on the libvirt path).

## Data flow

### Gateway provisioning (Proxmox path)

```
1. nym_network/tasks/main.yml: include network-proxmox.yml
   → pvesh creates SDN zone `nymz`, vnet `nymiso`, applies pending SDN

2. nym_network/tasks/gateway.yml: render gateway-user-data.yaml.j2 to /tmp on control host
   (template uses var.nym_network.gateway.* + nym_network.ssh_public_keys; SOPS-decrypted vars used at render time)

3. include_role: proxmox_provision (gateway role)
   a. preflight.yml: verify AWS SSO + SSH-as-root reach
   b. ensure_image.yml: for each image in proxmox_provision.images:
      - stat /var/lib/vz/template/iso/<filename> on Proxmox (delegate_to root@proxmox)
      - if missing or sha256 mismatch:
        - if kind=s3: presign on localhost via aws s3 presign --profile <profile>
        - get_url with checksum: sha256:<value> on Proxmox (delegate_to)
   c. snippets.yml: copy /tmp/<vm_name>-user-data.yaml → /var/lib/vz/snippets/<vm_name>-user-data.yaml
                    copy /tmp/<vm_name>-network-config.yaml → /var/lib/vz/snippets/<vm_name>-network-config.yaml
   d. vm.yml:
      - qm status 200 → register existence
      - if absent: qm create 200 --name nym-gateway --cores ... --serial0 socket --vga serial0 --ostype l26 --tags "nym;gateway"
      - if absent: qm importdisk 200 /var/lib/vz/template/iso/jammy-server-cloudimg-amd64.img ceph-vms --format raw
      - qm set 200 --virtio0 ceph-vms:vm-200-disk-0,iothread=1,discard=on
                  --boot order=virtio0
                  --ide2 ceph-vms:cloudinit
                  --cicustom "user=local:snippets/nym-gateway-user-data.yaml,network=local:snippets/nym-gateway-network-config.yaml"
                  --net0 virtio,bridge=vmbr0
                  --net1 virtio,bridge=nymiso
      - qm resize 200 virtio0 20G  (failed_when: false — resize errors if already at size)
      - qm start 200  (only if previous status was stopped or absent)

4. VM boots; cloud-init reads snippets from cicustom drive; runs the existing nym-vpn-cli + nftables flow.
   Role does NOT poll for guest agent — that was the bpg pain point. Verification is manual / smoke test.
```

### Client provisioning (Proxmox path)

Same as gateway except:
- No cicustom drive (Kicksecure has networking baked in).
- Single NIC on `nymiso` (no LAN access by design).
- No snippet rendering, no snippet upload.
- `vm_internal_net` not set (only one NIC).

The Kicksecure image's IP must match `nym_network.client_internal_ip`. This is a documented constraint: changing the var without rebuilding the image leaves the client unreachable on the expected IP. Same constraint as the abandoned Terraform design.

### SDN ensure (Proxmox path)

`nym_network/tasks/network-proxmox.yml`:

```yaml
- pvesh get /cluster/sdn/zones/{{ sdn_zone }} || pvesh create /cluster/sdn/zones --type simple --zone {{ sdn_zone }}
- pvesh get /cluster/sdn/vnets/{{ sdn_vnet }} || pvesh create /cluster/sdn/vnets --vnet {{ sdn_vnet }} --zone {{ sdn_zone }}
- pvesh set /cluster/sdn   (apply pending; idempotent)
```

Each step `delegate_to: root@proxmox`. The conditional create handles re-runs without errors.

## Error handling

| Failure | Surfaced where | User action |
|---|---|---|
| AWS SSO expired | preflight.yml | `aws sso login --profile <profile>` (hint surfaced from CLI stderr) |
| SSH agent missing or wrong key | preflight.yml | `ssh-add ~/.ssh/id_ed25519`; verify `ssh root@proxmox.ts.paulo.software.vpn hostname` works manually |
| Image checksum mismatch on disk | ensure_image.yml | Re-run; get_url re-downloads |
| Image checksum still wrong post-download | get_url failure | Update var or fix image at source |
| `qm create` fails (VMID collision) | vm.yml | Override `vmid` per-VM or change `proxmox_provision.vmid_pool_start` |
| `qm importdisk` fails mid-flight | vm.yml | Re-run with `--tags destroy,recover` (TBD recover tag, see Open items) |
| Cloud-init never completes | not detected by role | Manual: `qm status 200`, ssh in, check `/var/log/cloud-init-output.log` |
| SDN zone/vnet name has hyphens | pvesh create | Var validation: defaults are `nymz`/`nymiso`; document the ≤8-alphanum constraint |
| S3 presigned URL HEAD fails | not in our path | We use GET via `get_url`; HEAD-on-presigned is the bpg-only failure mode |
| Proxmox host unreachable (tailnet down, host off) | preflight SSH check | Surface from `ssh` stderr; user fixes infra |

## Testing

1. **Syntax:** `ansible-playbook --syntax-check playbooks/nym-network-proxmox.yml`
2. **Dry-run:** `ansible-playbook --check playbooks/nym-network-proxmox.yml` — partial coverage; shell tasks don't run in check mode by default.
3. **End-to-end smoke test** (manual, against live Proxmox):
   - Plan completes without errors after one `aws sso login` and a working `ssh-agent`.
   - First run: ~5–8 min (Ubuntu image ~700 MB + Kicksecure ~1.5 GB + VM creates + cloud-init).
   - Re-run: <30s, no changes (idempotent).
   - Smoke checks:
     - `qm guest cmd 200 ping` returns ok (cloud-init done, qemu-guest-agent up)
     - `ssh ubuntu@<gateway-LAN-IP>` works
     - From client (via gateway as jump host or VNC console): `ping 10.55.0.1` succeeds
     - From client: `curl ifconfig.me` resolves to a Nym exit IP (not the home LAN IP)
     - Stop nym-vpn on gateway → from client: `curl --max-time 5 ifconfig.me` times out (kill switch holds)
4. **Destroy + redeploy:** `ansible-playbook --tags destroy` then re-apply. Verify clean teardown of VMs (SDN stays).

No automated integration test infrastructure (would need a Proxmox sandbox; expensive to maintain).

## Security notes

- Same threat model as the libvirt path: client has no direct internet; all traffic forced through Nym via gateway; kill switch blocks leaks if Nym daemon dies; no IPv6.
- New surface area: per-image AWS profiles in inventory. Profile name is not sensitive (it's a local CLI profile reference). The actual AWS credentials live in `~/.aws/sso/cache/` on the control host, refreshed via `aws sso login` — same as our existing setup.
- SSH-as-root to Proxmox is unchanged from current operational reality (you SSH there for everything). No new credential surface.
- Cloud-init template still contains the Nym mnemonic when fully rendered. SOPS-encrypted in inventory; rendered to `/tmp` on the control host (not committed); copied to Proxmox `/var/lib/vz/snippets/` (root-readable only on Proxmox host). Snippets cleaned up by `destroy.yml`.

## Pre-flight checklist (one-time and per-run)

One-time setup (already done from the Terraform attempt or otherwise):
- [x] Snippets content type enabled on `local` Proxmox datastore
- [x] SSH key authorized for `root@proxmox.ts.paulo.software.vpn`
- [x] AWS profile `personal-admin-management` configured locally (SSO)
- [x] `paulao-vm-images` S3 bucket exists with `kicksecure-client-base.qcow2`

Per-run setup:
- [ ] `aws sso login --profile personal-admin-management` (1-hour TTL)
- [ ] `ssh-add ~/.ssh/id_ed25519` (or have a persistent agent)
- [ ] `ssh root@proxmox.ts.paulo.software.vpn hostname` returns successfully

Pin checksums (one-time per image rotation):
- [ ] `nym_network.proxmox.images.gateway.sha256`: from Ubuntu's `SHA256SUMS` at the URL prefix
- [ ] `nym_network.proxmox.images.client.sha256`: from your image-build pipeline or computed on first download

## Risk register

| # | Risk | Probability | Blast radius | Mitigation |
|---|---|---|---|---|
| 1 | `qm` semantics shift in PVE 10 | Low | Low | Pin to PVE 9; lockstep with image stack |
| 2 | Tailnet to Proxmox unstable mid-run | Medium | Medium | Preflight surfaces it; resume by re-running (idempotent) |
| 3 | Kicksecure image IP drifts from `client_internal_ip` var | Medium | Medium | Documented constraint; rebuild image when var changes |
| 4 | AWS SSO expires mid-run (>1 hour deploy) | Low | Low | Presign happens early; 3600s TTL on URL; re-run continues from checksum check |
| 5 | `qm importdisk` half-completes (unique because not idempotent) | Medium | Medium | Recovery path: `qm destroy {{ vmid }} --purge --skiplock` then re-run |
| 6 | SDN apply takes >30s and times out | Low | Low | `pvesh set /cluster/sdn` is synchronous but not slow on single-node |
| 7 | Two concurrent runs collide on the same VMID | Low | Medium | Don't run concurrently; document |
| 8 | Ceph pool `vms` out of space | Low | High | External monitoring (Grafana via existing observability stack) |
| 9 | Deprecated `qm` flags between minor PVE updates | Low | Low | Pin Proxmox version in inventory; smoke test before upgrades |

## Decisions captured

| # | Decision | Value |
|---|---|---|
| 1 | Boundary: split provisioner into a sibling role | `proxmox_provision/` mirrors `kvm_provision/` |
| 2 | Auth | SSH-as-root only; no Proxmox API token |
| 3 | Snippet upload | `ansible.builtin.copy` over SSH (no API equivalent for snippets) |
| 4 | Isolated network | Proxmox SDN simple zone + vnet via `pvesh` (no SDN modules in `community.general.proxmox`) |
| 5 | Image management | Self-healing checksum-gated `get_url` on Proxmox; presign on control host for S3 images |
| 6 | Per-image AWS profile | Yes, in image vars (not role default) |
| 7 | Presign location | Control host (`delegate_to: localhost`); Proxmox doesn't need AWS CLI |
| 8 | Backend dispatch | Single var `nym_network.provision_backend` (`libvirt` | `proxmox`) |
| 9 | API library | None — pure SSH+`qm`+`pvesh` |
| 10 | Disk format | `qm importdisk ... --format raw` (matches Ceph RBD) |
| 11 | Tags on Proxmox VMs | `nym;<role>` (drop `terraform` tag from the prior attempt) |
| 12 | Default VMIDs | gateway 200, client 201 |
| 13 | Playbook target | `localhost` with `delegate_to` (separate playbook from libvirt's) |
| 14 | Scope | Nym only; lokinet is a follow-up that reuses `proxmox_provision` |
| 15 | Cloud-init wait | None — role does not poll for guest agent or cloud-init completion |

## Open items (resolved during implementation)

| Item | Resolution path |
|---|---|
| Exact `sha256` for Ubuntu jammy and Kicksecure | Compute on first apply (have Proxmox-side image still pre-seeded; sha256 it) |
| Recovery tag (`destroy,recover`) for half-imported disks | Add as `--tags recover` cleanup task in `destroy.yml`: `qm stop && qm destroy --purge` |
| Whether Kicksecure image needs `qm set --agent enabled=1` | Test on first deploy; if guest agent absent, document and set `enabled=0` |
| Sensitive var encryption strategy for `proxmox_provision.images.client.sha256` | Not sensitive (it's a hash). No encryption needed |
| Whether to support N gateways / N clients | Out of scope for v1; current design is one-of-each |

## Follow-up projects (explicitly deferred)

- `lokinet_network` Proxmox port (reuses `proxmox_provision` unchanged).
- Bake a Nym-gateway golden image (matching the Kicksecure pattern) to remove cloud-init from the Proxmox path entirely.
- Multi-node Proxmox HA support.
- Proxmox node dynamic discovery via inventory rather than hard-coded SSH host.
- Automated integration testing against a Proxmox sandbox.
- Migrate the SDN ensure to a future `community.general.proxmox_sdn_*` module if/when it lands.

## References

- `roles/nym_network/` (existing on `feat/nym-network-ansible`) — the libvirt-side role this design extends
- `roles/kvm_provision/` (existing) — the pattern this design mirrors with `proxmox_provision/`
- `tech-docs/01-cheatsheets/proxmox.md` — Proxmox host reference, `qm`/`pvesh`/`pvesm` recipes
- `tech-docs/03-reports/2026-04-20-nym-network-ansible-migration-report.md` — origin of the libvirt → Ansible migration
- `terraform-kvm/docs/superpowers/specs/2026-04-23-nym-network-proxmox-module-design.md` — the abandoned Terraform attempt; shares constraints (SDN ID format, VMID pool, storage layout)
- `terraform-kvm/scripts/proxmox-rollback-nym.sh` — cleans up Proxmox-side state from the abandoned attempt; should be run before first apply of this Ansible role
