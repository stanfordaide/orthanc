# ═══════════════════════════════════════════════════════════════════════════════
# ORTHANC PACS - Makefile
# ═══════════════════════════════════════════════════════════════════════════════
# Common operations for managing Orthanc
#
# Usage: make <target>
#
# Override storage paths during setup:
#   make setup DICOM_STORAGE=/mnt/nas/dicom POSTGRES_STORAGE=/data/postgres
#
# ═══════════════════════════════════════════════════════════════════════════════

.PHONY: help setup install quick-setup start stop restart logs status clean upgrade backup

# Overridable variables with defaults
DICOM_STORAGE ?= /opt/orthanc/orthanc-storage
POSTGRES_STORAGE ?= /opt/orthanc/postgres-data
ORTHANC_AET ?= ORTHANC_LPCH

# Load .env if it exists (values from .env take precedence)
-include .env

# Default target
help:
	@echo "🏥 ORTHANC MANAGEMENT"
	@echo ""
	@echo "SETUP"
	@echo "  make setup                  Interactive setup wizard"
	@echo "  make quick-setup            Quick setup with defaults"
	@echo "  make setup DICOM_STORAGE=/path POSTGRES_STORAGE=/path"
	@echo "                              Setup with custom paths"
	@echo ""
	@echo "SERVICE MANAGEMENT"
	@echo "  make start                  Start all services"
	@echo "  make stop                   Stop all services"
	@echo "  make restart                Restart all services"
	@echo "  make logs                   View logs (Ctrl+C to exit)"
	@echo "  make status                 Show service status"
	@echo ""
	@echo "MAINTENANCE"
	@echo "  make upgrade                Pull latest images and restart"
	@echo "  make backup                 Create backup (not implemented)"
	@echo "  make clean                  Remove containers (keep data)"
	@echo ""
	@echo "PORTS (defaults)"
	@echo "  8040  Operator Dashboard"
	@echo "  8041  Orthanc Web UI / API"
	@echo "  8042  OHIF Viewer"
	@echo "  4242  DICOM"
	@echo ""
	@echo "EXAMPLES"
	@echo "  # First time setup with custom NAS storage:"
	@echo "  make setup DICOM_STORAGE=/mnt/nas/orthanc/dicom"
	@echo ""
	@echo "  # Quick setup with local storage:"
	@echo "  make quick-setup"

# ─────────────────────────────────────────────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────────────────────────────────────────────

# Interactive setup wizard
setup:
	@chmod +x setup.sh
	@DICOM_STORAGE="$(DICOM_STORAGE)" \
	 POSTGRES_STORAGE="$(POSTGRES_STORAGE)" \
	 ORTHANC_AET="$(ORTHANC_AET)" \
	 ./setup.sh

# Quick setup with defaults or overrides
quick-setup:
	@chmod +x setup.sh
	@./setup.sh --defaults \
		--dicom "$(DICOM_STORAGE)" \
		--db "$(POSTGRES_STORAGE)" \
		--aet "$(ORTHANC_AET)"

# Alias for backwards compatibility
install: setup

# ─────────────────────────────────────────────────────────────────────────────────
# SERVICE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────────

start:
	@docker compose up -d
	@echo "✅ Services started"
	@echo ""
	@echo "  Dashboard: http://localhost:$${OPERATOR_UI_PORT:-8040}"
	@echo "  Orthanc:   http://localhost:$${ORTHANC_WEB_PORT:-8041}"
	@echo "  OHIF:      http://localhost:$${OHIF_PORT:-8042}"

stop:
	@docker compose stop
	@echo "✅ Services stopped"

restart:
	@docker compose restart
	@echo "✅ Services restarted"

logs:
	@docker compose logs -f

status:
	@./orthanc status

# ─────────────────────────────────────────────────────────────────────────────────
# MAINTENANCE
# ─────────────────────────────────────────────────────────────────────────────────

upgrade:
	@echo "📥 Pulling latest images..."
	@docker compose pull
	@echo "🔄 Restarting services..."
	@docker compose up -d
	@echo "✅ Upgrade complete"

backup:
	@echo "⚠️  Backup not implemented yet"
	@echo ""
	@echo "Manual backup:"
	@echo "  1. Stop services: make stop"
	@echo "  2. Copy your DICOM_STORAGE: $(DICOM_STORAGE)"
	@echo "  3. Copy your POSTGRES_STORAGE: $(POSTGRES_STORAGE)"
	@echo "  4. Start services: make start"

clean:
	@docker compose down
	@echo "✅ Containers removed (data preserved)"
	@echo ""
	@echo "Data locations:"
	@echo "  DICOM:    $(DICOM_STORAGE)"
	@echo "  Postgres: $(POSTGRES_STORAGE)"

# ─────────────────────────────────────────────────────────────────────────────────
# DEVELOPMENT
# ─────────────────────────────────────────────────────────────────────────────────

dev-shell:
	@docker compose exec orthanc /bin/bash

dev-db:
	@docker compose exec orthanc-db psql -U orthanc -d orthanc

dev-logs-orthanc:
	@docker compose logs -f orthanc

dev-logs-db:
	@docker compose logs -f orthanc-db

# ─────────────────────────────────────────────────────────────────────────────────
# VALIDATION
# ─────────────────────────────────────────────────────────────────────────────────

validate:
	@echo "🔍 Validating configuration..."
	@[ -f .env ] && echo "  ✅ .env file exists" || echo "  ❌ .env file missing (run: make setup)"
	@[ -f config/orthanc.json ] && echo "  ✅ orthanc.json exists" || echo "  ❌ orthanc.json missing"
	@[ -d "$(DICOM_STORAGE)" ] && echo "  ✅ DICOM storage exists: $(DICOM_STORAGE)" || echo "  ⚠️  DICOM storage missing: $(DICOM_STORAGE)"
	@[ -d "$(POSTGRES_STORAGE)" ] && echo "  ✅ Postgres storage exists: $(POSTGRES_STORAGE)" || echo "  ⚠️  Postgres storage missing: $(POSTGRES_STORAGE)"
	@docker compose config > /dev/null && echo "  ✅ docker-compose.yml valid" || echo "  ❌ docker-compose.yml invalid"
	@echo ""
	@echo "Run 'make setup' to fix any issues."
