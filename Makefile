# Ansible Makefile
# Usage:
#   make setup          - Install dependencies
#   make run            - Run main playbook
#   make oci-homelab    - Run OCI homelab playbook
#   make networking     - Run networking role only
#   make users          - Run users role only
#
# Use HOST=<host> to limit to specific hosts (comma-separated for multiple)
# Example: make networking HOST=stremio-rpi
# Example: make oci-homelab TAGS=wireguard

SHELL := /bin/bash
.ONESHELL:

# Configuration
VENV := .venv
INVENTORY := hosts.yml
TEMP_INVENTORY := /tmp/ansible_inventory_$$(id -u).yml
HOST ?=
PLAYBOOK ?= playbooks/main.yml
TAGS ?=

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

# Activate venv
define setup_env
	source $(VENV)/bin/activate
endef

# Decrypt inventory to temp file
define decrypt_inventory
	@echo "Decrypting inventory..."
	@sops -d $(INVENTORY) > $(TEMP_INVENTORY)
	@chmod 600 $(TEMP_INVENTORY)
endef

# Clean up temp inventory
define cleanup_inventory
	rm -f $(TEMP_INVENTORY)
endef

.PHONY: help setup run oci-homelab networking users syncthing docker pxe edit-secrets clean

help:
	@echo "Available targets:"
	@echo "  setup          - Install Python venv and Ansible dependencies"
	@echo "  run            - Run main playbook (all roles)"
	@echo "  oci-homelab    - Run OCI homelab playbook (WireGuard + DNS)"
	@echo "  networking     - Run networking role only"
	@echo "  users          - Run users role only"
	@echo "  syncthing      - Run syncthing role only"
	@echo "  docker         - Run docker role only"
	@echo "  pxe            - Run PXE server role only"
	@echo "  edit-secrets   - Edit encrypted inventory with SOPS"
	@echo "  clean          - Remove temp files"
	@echo ""
	@echo "Use HOST=<host> to limit to specific hosts (comma-separated)"
	@echo "Use TAGS=<tag> to run specific tags only"
	@echo "Example: make networking HOST=stremio-rpi"
	@echo "Example: make oci-homelab TAGS=wireguard"

setup:
	@echo "Creating virtual environment..."
	python3 -m venv $(VENV)
	source $(VENV)/bin/activate && pip install --upgrade pip
	source $(VENV)/bin/activate && pip install ansible
	source $(VENV)/bin/activate && ansible-galaxy collection install -r requirements.yml
	source $(VENV)/bin/activate && ansible-galaxy collection install community.sops
	@echo "Setup complete!"

run:
	$(setup_env)
	$(decrypt_inventory)
	@trap '$(cleanup_inventory)' EXIT; \
	ansible-playbook -i $(TEMP_INVENTORY) $(PLAYBOOK) $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

networking:
	$(setup_env)
	$(decrypt_inventory)
	@trap '$(cleanup_inventory)' EXIT; \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t networking $(LIMIT_FLAG) $(ARGS)

users:
	$(setup_env)
	$(decrypt_inventory)
	@trap '$(cleanup_inventory)' EXIT; \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t users $(LIMIT_FLAG) $(ARGS)

syncthing:
	$(setup_env)
	$(decrypt_inventory)
	@trap '$(cleanup_inventory)' EXIT; \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t syncthing $(LIMIT_FLAG) $(ARGS)

docker:
	$(setup_env)
	$(decrypt_inventory)
	@trap '$(cleanup_inventory)' EXIT; \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t docker $(LIMIT_FLAG) $(ARGS)

pxe:
	$(setup_env)
	$(decrypt_inventory)
	@trap '$(cleanup_inventory)' EXIT; \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/main.yml -t pxe $(LIMIT_FLAG) $(ARGS)

oci-homelab:
	$(setup_env)
	$(decrypt_inventory)
	@trap '$(cleanup_inventory)' EXIT; \
	ansible-playbook -i $(TEMP_INVENTORY) playbooks/oci-homelab.yml $(LIMIT_FLAG) $(TAGS_FLAG) $(ARGS)

edit-secrets:
	@sops $(INVENTORY)

clean:
	@rm -f /tmp/ansible_inventory_*.yml
	@echo "Cleaned up temp files."
