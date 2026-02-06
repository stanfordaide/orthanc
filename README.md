# 🏥 Orthanc PACS

A containerized PACS (Picture Archiving and Communication System) with an operator-friendly dashboard.

## Quick Start

```bash
# 1. Clone and setup
git clone <repo>
cd orthanc
make install

# 2. Start services
make start

# 3. Open dashboard
open http://localhost:8040
```

## Ports

| Port | Service | Description |
|------|---------|-------------|
| **8040** | Operator Dashboard | Main management interface |
| **8041** | Orthanc | PACS Web UI & REST API |
| **8042** | OHIF Viewer | Clinical image viewer |
| **8043** | PostgreSQL | Database (for tools) |
| **4242** | DICOM | DICOM protocol |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      YOUR BROWSER                            │
│                                                              │
│   localhost:8040    localhost:8041    localhost:8042        │
│        │                 │                 │                 │
└────────┼─────────────────┼─────────────────┼─────────────────┘
         │                 │                 │
         ▼                 ▼                 ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Operator   │    │   Orthanc   │    │    OHIF     │
│  Dashboard  │───▶│    PACS     │◀───│   Viewer    │
└─────────────┘    └──────┬──────┘    └─────────────┘
                          │
                   ┌──────┴──────┐
                   │  PostgreSQL │
                   └─────────────┘
```

## Commands

### Using Make

```bash
make install    # First-time setup
make start      # Start services
make stop       # Stop services
make restart    # Restart services
make logs       # View logs
make status     # System status
make upgrade    # Update to latest
make clean      # Remove containers
```

### Using CLI

```bash
./orthanc status        # System overview
./orthanc studies       # List studies
./orthanc destinations  # List DICOM destinations
./orthanc test MERCURE  # Test a destination
./orthanc logs          # View logs
./orthanc shell         # Enter Orthanc container
./orthanc db            # Enter PostgreSQL
./orthanc help          # All commands
```

## Configuration

Copy the template and edit `.env` to customize:

```bash
cp config/env.template .env
```

Default settings (from your original config):

```bash
# Ports (sequential from 8040)
OPERATOR_UI_PORT=8040
ORTHANC_WEB_PORT=8041
OHIF_PORT=8042
POSTGRES_PORT=8043

# DICOM
ORTHANC_AET=ORTHANC_LPCH
DICOM_PORT=4242

# Storage paths (your original /opt/orthanc locations)
DICOM_STORAGE=/opt/orthanc/orthanc-storage
POSTGRES_STORAGE=/opt/orthanc/postgres-data

# Credentials (your original)
ORTHANC_USERNAME=orthanc_admin
ORTHANC_PASSWORD=helloaide123
POSTGRES_PASSWORD=ChangeThisPassword  # Set this!
```

**Important:** Set `POSTGRES_PASSWORD` in `.env` and update it in `config/orthanc.json` to match.

## Pre-configured DICOM Destinations

Your original modalities are preserved in `config/orthanc.json`:

| Name | AE Title | Host | Port |
|------|----------|------|------|
| MERCURE | orthanc | 172.17.0.1 | 11112 |
| LPCHROUTER | LPCHROUTER | 10.50.133.21 | 4000 |
| LPCHTROUTER | LPCHTROUTER | 10.50.130.114 | 4000 |
| MODLINK | PSRTBONEAPP01 | 10.251.201.59 | 104 |

## Adding DICOM Destinations

Via the Orthanc API (no restart needed):

```bash
# Add a destination
curl -X PUT http://localhost:8041/modalities/MY_PACS \
  -u orthanc_admin:orthanc \
  -d '["MY_AET", "192.168.1.100", 4242]'

# Test it
curl -X POST http://localhost:8041/modalities/MY_PACS/echo \
  -u orthanc_admin:orthanc
```

Or use the dashboard at http://localhost:8040

## File Structure

```
orthanc/
├── docker-compose.yml      # Service definitions
├── .env                    # Your configuration
├── orthanc                 # CLI tool
├── Makefile               # Common operations
│
├── config/
│   ├── orthanc.json       # Orthanc settings
│   ├── nginx.conf         # OHIF proxy
│   └── env.template       # Config template
│
├── ui/
│   ├── index.html         # Operator dashboard
│   └── nginx.conf         # Dashboard proxy
│
├── lua/
│   └── route_engine.lua   # Routing logic
│
├── init/
│   └── 001_routing_state.sql  # DB schema
│
└── data/                  # Persistent data
    ├── dicom/            # DICOM files
    └── postgres/         # Database
```

## Troubleshooting

### Services won't start

```bash
# Check logs
docker compose logs

# Check if ports are in use
lsof -i :8040 -i :8041 -i :8042 -i :4242
```

### Orthanc not connecting to database

```bash
# Check database is ready
docker compose logs orthanc-db

# Database should show "ready to accept connections"
```

### DICOM destination unreachable

```bash
# Test from Orthanc container
./orthanc shell
curl -v telnet://DESTINATION_IP:PORT
```

## License

See LICENSE file.
