# ═══════════════════════════════════════════════════════════════════════════════
# ORTHANC PACS - Makefile
# ═══════════════════════════════════════════════════════════════════════════════
# Common operations for managing Orthanc
#
# Usage: make <target>
# ═══════════════════════════════════════════════════════════════════════════════

.PHONY: help install start stop restart logs status clean upgrade backup

# Default target
help:
	@echo "🏥 ORTHANC MANAGEMENT"
	@echo ""
	@echo "SETUP"
	@echo "  make install     First-time setup (create dirs, copy config)"
	@echo ""
	@echo "SERVICE MANAGEMENT"
	@echo "  make start       Start all services"
	@echo "  make stop        Stop all services"
	@echo "  make restart     Restart all services"
	@echo "  make logs        View logs (Ctrl+C to exit)"
	@echo "  make status      Show service status"
	@echo ""
	@echo "MAINTENANCE"
	@echo "  make upgrade     Pull latest images and restart"
	@echo "  make backup      Create backup (not implemented)"
	@echo "  make clean       Remove containers (keep data)"
	@echo ""
	@echo "PORTS"
	@echo "  8040  Operator Dashboard"
	@echo "  8041  Orthanc Web UI / API"
	@echo "  8042  OHIF Viewer"
	@echo "  4242  DICOM"

# ─────────────────────────────────────────────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────────────────────────────────────────────

install:
	@echo "🔧 Setting up Orthanc..."
	@# Create data directories
	@mkdir -p data/dicom data/postgres
	@# Copy config if not exists
	@[ -f .env ] || cp config/env.template .env
	@# Make CLI executable
	@chmod +x orthanc
	@echo ""
	@echo "✅ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Edit .env to set passwords (or leave empty for defaults)"
	@echo "  2. Run: make start"
	@echo "  3. Open: http://localhost:8040"

# ─────────────────────────────────────────────────────────────────────────────────
# SERVICE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────────

start:
	@docker compose up -d
	@echo "✅ Services started"
	@echo ""
	@echo "  Dashboard: http://localhost:8040"
	@echo "  Orthanc:   http://localhost:8041"
	@echo "  OHIF:      http://localhost:8042"

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
	@echo "Manual backup:"
	@echo "  1. Stop services: make stop"
	@echo "  2. Copy data/dicom and data/postgres"
	@echo "  3. Start services: make start"

clean:
	@docker compose down
	@echo "✅ Containers removed (data preserved in ./data/)"

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
