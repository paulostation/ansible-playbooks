# Atuin Shell History - Design Document

## Overview

Add Atuin shell history tool to the `dev.utils` role with automated registration and SOPS-encrypted credentials.

## Installation Approach

**Binary Installation:**
- Use official install script: `curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh`
- Runs as the target user (not root)
- Installs to `~/.atuin/bin/atuin`

**Shell Integration:**
- Add `eval "$(atuin init zsh)"` to `.zshrc` after Oh My Zsh is sourced
- Uses blockinfile to ensure idempotency

**Task placement:**
- New file: `roles/dev.utils/tasks/atuin.yml`
- Included from `main.yml`

## Registration with SOPS Secrets

**Secret Storage:**
- Add Atuin credentials to host/group vars in inventory
- Fields named `atuin_username`, `atuin_email`, `atuin_password` will auto-encrypt via existing SOPS regex

**Registration Automation:**
```bash
atuin register -u <username> -e <email> -p <password>
```

**Login for Existing Accounts:**
```bash
atuin login -u <username> -p <password>
```

**Idempotency Strategy:**
- Check if `~/.local/share/atuin/session` exists (indicates logged in)
- Skip registration/login if session already exists
- Use `creates:` parameter or conditional check

**Task Flow:**
1. Install binary
2. Init shell integration
3. Check if session exists
4. If no session + credentials provided: attempt login first (in case already registered)
5. If login fails: register new account
6. Run `atuin sync` to pull history

## Configuration & Sync Settings

**Atuin Config File:**
- Location: `~/.config/atuin/config.toml`
- Template with sensible defaults

**Key Configuration Options:**
```toml
dialect = "us"
auto_sync = true
sync_frequency = "1h"
search_mode = "fuzzy"
filter_mode = "global"
style = "auto"
inline_height = 0
```

**History Import:**
- Run `atuin import auto` after registration to import existing zsh/bash history
- One-time operation, use a marker file to track completion

**Role Variables (defaults/main.yml):**
```yaml
atuin_enabled: true
atuin_sync_enabled: true
atuin_sync_frequency: "1h"
atuin_search_mode: "fuzzy"
atuin_import_history: true
```

**Credentials (in inventory, SOPS-encrypted):**
```yaml
atuin_username: "myuser"
atuin_email: "me@example.com"
atuin_password: "secret123"  # Auto-encrypted by SOPS
```

## File Structure

**New/Modified Files:**

```
roles/dev.utils/
├── defaults/main.yml              # NEW: Add atuin defaults
├── tasks/
│   ├── main.yml                   # MODIFY: Include atuin.yml
│   └── atuin.yml                  # NEW: Atuin installation tasks
├── templates/
│   └── atuin-config.toml.j2       # NEW: Config template
└── files/
    └── .zshrc                     # MODIFY: Add atuin init
```

**Task Order in atuin.yml:**
1. Install Atuin binary (curl script)
2. Ensure ~/.config/atuin directory exists
3. Deploy config.toml template
4. Add shell integration to .zshrc
5. Check if session exists
6. Login or register (when sync enabled + credentials provided)
7. Import history (one-time, with marker file)
8. Initial sync

**Tags:**
- `atuin` - Run only Atuin tasks
- `dev_utils` - Existing tag includes Atuin

**Idempotency Markers:**
- `~/.atuin/bin/atuin` - Binary installed
- `~/.local/share/atuin/session` - Logged in
- `~/.local/share/atuin/.history_imported` - History imported
