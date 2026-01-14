# Ansible Makefile with SOPS integration (age encryption)
# Uses community.sops collection for native decryption - no temp files needed!
#
# Usage:
#   make setup          - Install dependencies
#   make setup-sops     - Setup SOPS + age encryption (run once per machine)
#   make run            - Run main playbook
#   make edit-secrets   - Edit encrypted inventory
#   make encrypt-hosts  - Encrypt hosts.yml to hosts.sops.yml
#   make decrypt        - Decrypt inventory to stdout
#
# Use HOST=<host> to limit to specific hosts (comma-separated for multiple)
# Example: make run HOST=myserver PLAYBOOK=playbooks/dev_utils.yml

SHELL := /bin/bash
.ONESHELL:

# Configuration
VENV := .venv
INVENTORY := hosts.sops.yml
HOST ?=
PLAYBOOK ?= playbooks/main.yml
TAGS ?=

# SOPS age key location
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

# Build limit flag if HOST is provided
ifdef HOST
  LIMIT_FLAG := -l $(HOST)
else
  LIMIT_FLAG :=
endif

# Build tags flag if TAGS is provided
ifdef TAGS
  TAGS_FLAG := -t $(TAGS)
else
  TAGS_FLAG :=
endif

# Temp file for decrypted inventory
TEMP_INVENTORY := /tmp/ansible_inventory_$$(id -u).yml

# Environment for ansible with SOPS support
define ansible_env
	source $(VENV)/bin/activate && \
	export SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE)
endef

# Decrypt inventory, run command, cleanup on exit
define run_with_inventory
	$(ansible_env) && \
	sops -d $(INVENTORY) > $(TEMP_INVENTORY) && \
	chmod 600 $(TEMP_INVENTORY) && \
	trap 'rm -f $(TEMP_INVENTORY)' EXIT &&
endef

.PHONY: help setup setup-sops run dev nvim networking users syncthing docker pxe edit-secrets encrypt-hosts decrypt clean

help:
	@echo "Available targets:"
	@echo "  setup          - Install Python venv and Ansible dependencies"
	@echo "  setup-sops     - Setup SOPS + age encryption (run once per machine)"
	@echo "  run            - Run playbook (default: main.yml)"
	@echo "  dev            - Run dev_utils playbook"
	@echo "  nvim           - Run neovim setup playbook"
	@echo "  networking     - Run networking role only"
	@echo "  users          - Run users role only"
	@echo "  syncthing      - Run syncthing role only"
	@echo "  docker         - Run docker role only"
	@echo "  pxe            - Run PXE server role only"
	@echo "  edit-secrets   - Edit encrypted inventory with sops"
	@echo "  encrypt-hosts  - Encrypt hosts.yml to hosts.sops.yml"
	@echo "  decrypt        - Decrypt inventory to stdout"
	@echo "  clean          - Remove temp files and cache"
	@echo ""
	@echo "Variables:"
	@echo "  HOST=<host>      - Limit to specific host(s)"
	@echo "  PLAYBOOK=<path>  - Playbook to run (default: playbooks/main.yml)"
	@echo "  TAGS=<tags>      - Run only specific tags"
	@echo ""
	@echo "Examples:"
	@echo "  make dev HOST=localhost"
	@echo "  make run PLAYBOOK=playbooks/dev_utils.yml HOST=myserver"
	@echo "  make run TAGS=docker,syncthing"

setup:
	@echo "Creating virtual environment..."
	python3 -m venv $(VENV)
	source $(VENV)/bin/activate && pip install --upgrade pip
	source $(VENV)/bin/activate && pip install ansible
	source $(VENV)/bin/activate && ansible-galaxy collection install -r requirements.yml
	source $(VENV)/bin/activate && ansible-galaxy collection install community.sops community.general
	@echo "Setup complete!"

setup-sops:
	$(ansible_env) && \
	ansible-playbook -i hosts.yml playbooks/setup_sops.yml -l localhost $(ARGS)
	@echo ""
	@echo "SOPS setup complete! You can now encrypt your hosts.yml with:"
	@echo "  make encrypt-hosts"

# Main run target - decrypts inventory, runs playbook, cleans up
run:
	$(run_with_inventory) \
	ansible-playbook -i $(TEMP_INVENTORY) $(PLAYBOOK) $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

# Convenience targets for common playbooks
dev:
	$(run_with_inventory) \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/dev_utils.yml $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

nvim:
	$(run_with_inventory) \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/setup_neovim.yml $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

# Role-specific targets
networking:
	$(run_with_inventory) \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t networking $(LIMIT_FLAG) $(ARGS)

users:
	$(run_with_inventory) \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t users $(LIMIT_FLAG) $(ARGS)

syncthing:
	$(run_with_inventory) \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t syncthing $(LIMIT_FLAG) $(ARGS)

docker:
	$(run_with_inventory) \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t docker $(LIMIT_FLAG) $(ARGS)

pxe:
	$(run_with_inventory) \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t pxe $(LIMIT_FLAG) $(ARGS)

# SOPS operations
edit-secrets:
	@SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) sops $(INVENTORY)

encrypt-hosts:
	@if [ ! -f hosts.yml ]; then \
		echo "Error: hosts.yml not found"; \
		exit 1; \
	fi
	@if [ -f hosts.sops.yml ]; then \
		echo "Warning: hosts.sops.yml already exists. Backing up to hosts.sops.yml.bak"; \
		cp hosts.sops.yml hosts.sops.yml.bak; \
	fi
	@SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) sops -e hosts.yml > hosts.sops.yml
	@echo "hosts.yml encrypted to hosts.sops.yml"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Verify: make decrypt | head"
	@echo "  2. Backup hosts.yml somewhere safe"
	@echo "  3. Delete hosts.yml from repo (it contains secrets)"
	@echo "  4. Commit hosts.sops.yml"

decrypt:
	@SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) sops -d $(INVENTORY)

clean:
	@rm -f /tmp/ansible_inventory_*.yml
	@rm -rf .ansible_cache
	@echo "Cleaned up temp files."
