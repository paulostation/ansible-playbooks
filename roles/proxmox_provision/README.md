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

## Recovery from half-create state

If a run is interrupted between `qm create` and `qm importdisk` (network blip,
Ctrl-C), the next run will see the VM exists and skip the import, then fail at
`qm set --virtio0` because the disk wasn't created. Recovery is one command on
the Proxmox host: `qm destroy <vmid> --purge`. Then re-run the playbook.
