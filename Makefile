# Ansible Makefile with SOPS integration (age encryption)
# Usage:
#   make setup          - Install dependencies
#   make run            - Run main playbook
#   make networking     - Run networking role only
#   make users          - Run users role only
#   make edit-secrets   - Edit encrypted inventory
#   make encrypt        - Encrypt inventory file
#   make decrypt        - Decrypt inventory to stdout
#
# Use HOST=<host> to limit to specific hosts (comma-separated for multiple)
# Example: make networking HOST=stremio-rpi

SHELL := /bin/bash
.ONESHELL:

# Configuration
VENV := .venv
INVENTORY := hosts.sops.yml
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

.PHONY: help setup setup-sops run networking users syncthing docker pxe edit-secrets encrypt encrypt-hosts decrypt clean

help:
	@echo "Available targets:"
	@echo "  setup          - Install Python venv and Ansible dependencies"
	@echo "  setup-sops     - Setup SOPS + age encryption (run once per machine)"
	@echo "  run            - Run main playbook (all roles)"
	@echo "  networking     - Run networking role only"
	@echo "  users          - Run users role only"
	@echo "  syncthing      - Run syncthing role only"
	@echo "  docker         - Run docker role only"
	@echo "  pxe            - Run PXE server role only"
	@echo "  edit-secrets   - Edit encrypted inventory with sops"
	@echo "  encrypt        - Encrypt inventory file in-place"
	@echo "  encrypt-hosts  - Encrypt hosts.yml to hosts.sops.yml"
	@echo "  decrypt        - Decrypt inventory to stdout"
	@echo "  clean          - Remove temp files"
	@echo ""
	@echo "Use HOST=<host> to limit to specific hosts (comma-separated)"
	@echo "Example: make networking HOST=stremio-rpi"

setup:
	@echo "Creating virtual environment..."
	python3 -m venv $(VENV)
	source $(VENV)/bin/activate && pip install --upgrade pip
	source $(VENV)/bin/activate && pip install ansible
	source $(VENV)/bin/activate && ansible-galaxy collection install -r requirements.yml
	source $(VENV)/bin/activate && ansible-galaxy collection install community.sops
	@echo "Setup complete!"

setup-sops:
	$(setup_env)
	ansible-playbook -i hosts.yml playbooks/setup_sops.yml -l localhost $(ARGS)
	@echo ""
	@echo "SOPS setup complete! You can now encrypt your hosts.yml with:"
	@echo "  make encrypt-hosts"

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

edit-secrets:
	@sops $(INVENTORY)

encrypt:
	@sops -e -i $(INVENTORY)
	@echo "Inventory encrypted."

encrypt-hosts:
	@if [ ! -f hosts.yml ]; then \
		echo "Error: hosts.yml not found"; \
		exit 1; \
	fi
	@if [ -f hosts.sops.yml ]; then \
		echo "Warning: hosts.sops.yml already exists. Backing up to hosts.sops.yml.bak"; \
		cp hosts.sops.yml hosts.sops.yml.bak; \
	fi
	@sops -e hosts.yml > hosts.sops.yml
	@echo "hosts.yml encrypted to hosts.sops.yml"
	@echo "You can now safely remove hosts.yml if desired (keep a backup!)"

decrypt:
	@sops -d $(INVENTORY)

clean:
	@rm -f /tmp/ansible_inventory_*.yml
	@echo "Cleaned up temp files."
