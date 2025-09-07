# asdf_cli (Ansible role)

Installs [asdf](https://asdf-vm.com) for a target user and manages CLI tools (e.g., `jq`, `yq`) via plugins and global versions.

## Variables

- `asdf_user`: Owner of the installation (default: `{{ ansible_user }}`).
- `asdf_shell`: `"zsh"` or `"bash"`; used to wire init in your shell RC (default: `"zsh"`).
- `asdf_version`: asdf git tag, e.g., `"v0.14.0"` (default).
- `asdf_dir`: Where asdf is installed (default: `~/.asdf`).
- `asdf_plugins`: List of tool/version maps to install and set globally:
  ```yaml
  asdf_plugins:
    - name: jq
      version: "1.7.1"
    - name: yq
      version: "4.44.1"

