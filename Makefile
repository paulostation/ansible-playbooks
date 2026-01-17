# Ansible Makefile with SOPS integration (age encryption)
# Uses community.sops vars plugin for automatic decryption of secrets.sops.yml files
#
# Structure:
#   hosts.yml                           - Plain inventory (no secrets)
#   host_vars/<host>/secrets.sops.yml   - Per-host encrypted secrets
#   group_vars/<group>/secrets.sops.yml - Per-group encrypted secrets
#
# Usage:
#   make setup          - Install dependencies
#   make setup-sops     - Setup SOPS + age encryption (run once per machine)
#   make run            - Run main playbook
#   make edit HOST=foo  - Edit host's secrets.sops.yml
#
# Use HOST=<host> to limit to specific hosts (comma-separated for multiple)
# Example: make run HOST=myserver PLAYBOOK=playbooks/dev_utils.yml

SHELL := /bin/bash
.ONESHELL:

# Configuration
VENV := .venv
INVENTORY := hosts.yml
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

# Environment for ansible with SOPS support
define ansible_env
	source $(VENV)/bin/activate && \
	export SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE)
endef

.PHONY: help setup setup-sops run dev nvim vpn-hub vpn-client networking users syncthing docker pxe edit edit-group clean

help:
	@echo "Available targets:"
	@echo "  setup          - Install Python venv and Ansible dependencies"
	@echo "  setup-sops     - Setup SOPS + age encryption (run once per machine)"
	@echo "  run            - Run playbook (default: main.yml)"
	@echo "  dev            - Run dev_utils playbook"
	@echo "  nvim           - Run neovim setup playbook"
	@echo "  vpn-hub        - Run VPN hub playbook (WireGuard + DNS)"
	@echo "  vpn-client     - Run VPN client playbook (configure client)"
	@echo "  networking     - Run networking role only"
	@echo "  users          - Run users role only"
	@echo "  syncthing      - Run syncthing role only"
	@echo "  docker         - Run docker role only"
	@echo "  pxe            - Run PXE server role only"
	@echo "  edit           - Edit host secrets (requires HOST=<hostname>)"
	@echo "  edit-group     - Edit group secrets (requires GROUP=<groupname>)"
	@echo "  clean          - Remove temp files and cache"
	@echo ""
	@echo "Variables:"
	@echo "  HOST=<host>      - Limit to specific host(s)"
	@echo "  GROUP=<group>    - Group name for edit-group"
	@echo "  PLAYBOOK=<path>  - Playbook to run (default: playbooks/main.yml)"
	@echo "  TAGS=<tags>      - Run only specific tags"
	@echo ""
	@echo "Examples:"
	@echo "  make dev HOST=localhost"
	@echo "  make run PLAYBOOK=playbooks/dev_utils.yml HOST=myserver"
	@echo "  make run TAGS=docker,syncthing"
	@echo "  make edit HOST=mouse"
	@echo "  make edit-group GROUP=home"

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
	ansible-playbook -i $(INVENTORY) playbooks/setup_sops.yml -l localhost $(ARGS)
	@echo ""
	@echo "SOPS setup complete!"

# Main run target - community.sops plugin handles decryption automatically
run:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

# Convenience targets for common playbooks
dev:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/dev_utils.yml $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

nvim:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/setup_neovim.yml $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

vpn-hub:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/vpn-hub.yml $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

vpn-client:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/vpn-client.yml $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

# Role-specific targets
networking:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/main.yml -t networking $(LIMIT_FLAG) $(ARGS)

users:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/main.yml -t users $(LIMIT_FLAG) $(ARGS)

syncthing:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/main.yml -t syncthing $(LIMIT_FLAG) $(ARGS)

docker:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/main.yml -t docker $(LIMIT_FLAG) $(ARGS)

pxe:
	$(ansible_env) && \
	ansible-playbook -i $(INVENTORY) playbooks/main.yml -t pxe $(LIMIT_FLAG) $(ARGS)

# SOPS operations - edit per-host or per-group secrets
edit:
ifndef HOST
	$(error HOST is required. Usage: make edit HOST=hostname)
endif
	@if [ ! -f host_vars/$(HOST)/secrets.sops.yml ]; then \
		echo "Creating new secrets file for $(HOST)..."; \
		mkdir -p host_vars/$(HOST); \
		echo "# Secrets for $(HOST)" > host_vars/$(HOST)/secrets.sops.yml; \
	fi
	SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) sops host_vars/$(HOST)/secrets.sops.yml

edit-group:
ifndef GROUP
	$(error GROUP is required. Usage: make edit-group GROUP=groupname)
endif
	@if [ ! -f group_vars/$(GROUP)/secrets.sops.yml ]; then \
		echo "Creating new secrets file for group $(GROUP)..."; \
		mkdir -p group_vars/$(GROUP); \
		echo "# Secrets for $(GROUP) group" > group_vars/$(GROUP)/secrets.sops.yml; \
	fi
	SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) sops group_vars/$(GROUP)/secrets.sops.yml

clean:
	@rm -rf .ansible_cache
	@echo "Cleaned up cache files."
