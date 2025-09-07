# onepassword (Ansible role)

Installs 1Password on Debian/Ubuntu by configuring the official apt repository, signing key, and debsig-verify policy, then installs the `1password` package.

## Variables

See `defaults/main.yml`. Common ones:

- `onepassword_arch`: CPU arch (`amd64` default).
- `onepassword_update_cache`: Whether to `apt update` before install (default `true`).

## Example Playbook

```yaml
- hosts: all
  become: true
  roles:
    - role: onepassword


