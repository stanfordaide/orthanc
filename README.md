# 🏥 Orthanc PACS

A containerized PACS (Picture Archiving and Communication System) with an operator-friendly dashboard.

## Quick Start

```bash
# 1. Clone repository
git clone <repo>
cd orthanc

# 2. Run setup (interactive wizard)
make setup

# 3. Start services
make start

# 4. Open dashboard
open http://localhost:8040
```

## Installation Options

### Interactive Setup (Recommended)

```bash
make setup
```

This will prompt you for:
- DICOM storage path
- PostgreSQL data path
- AE Title
- Passwords

### Quick Setup with Defaults

```bash
make quick-setup
```

Uses default paths: `/opt/orthanc/orthanc-storage` and `/opt/orthanc/postgres-data`

### Custom Storage Paths

Override paths during setup:

```bash
# NAS storage for DICOM
make setup DICOM_STORAGE=/mnt/nas/orthanc/dicom

# Both paths customized
make setup DICOM_STORAGE=/data/dicom POSTGRES_STORAGE=/data/postgres

# Or via the setup script directly
./setup.sh --dicom /mnt/nas/dicom --db /data/postgres --aet MY_PACS
```

### Re-running Setup

It's safe to run `make setup` again on an existing installation. You'll be prompted to:
1. Update configuration (keeps existing data)
2. Keep existing configuration (just verify/start)
3. Cancel

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
│                      YOUR BROWSER                           │
│                                                             │
│   localhost:8040    localhost:8041    localhost:8042        │
│        │                 │                 │                │
└────────┼─────────────────┼─────────────────┼────────────────┘
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

### Setup & Installation

| Command | Description |
|---------|-------------|
| `make setup` | Interactive setup wizard (safe to re-run) |
| `make quick-setup` | Quick setup with defaults |
| `make setup DICOM_STORAGE=/path` | Setup with custom paths |

### Service Management

| Command | Description |
|---------|-------------|
| `make start` | Start all services |
| `make stop` | Stop all services |
| `make restart` | Restart all services |
| `make logs` | View logs (Ctrl+C to exit) |
| `make status` | System status |

### Maintenance

| Command | Description |
|---------|-------------|
| `make upgrade` | Pull latest images and restart |
| `make clean` | Stop containers (keeps data) |
| `make reset` | Reset config (keeps data, removes .env) |
| `make uninstall` | **DANGER:** Remove everything including data |

### CLI Tool

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

## Managing DICOM Destinations

### Via the Web UI (Recommended)

1. Open the Operator Dashboard: http://localhost:8040
2. In the "DICOM Destinations" section, click **+ Add**
3. Fill in:
   - **Name**: Unique identifier (e.g., `MY_PACS`)
   - **AE Title**: The destination's AE Title
   - **Host**: IP address or hostname
   - **Port**: DICOM port (usually 104 or 4242)
4. Click **Add** to save

To edit or delete: hover over a destination and click **Edit**

Changes take effect immediately—no restart required.

### Via the API

```bash
# Add a destination
curl -X PUT http://localhost:8041/modalities/MY_PACS \
  -u orthanc_admin:YOUR_PASSWORD \
  -H "Content-Type: application/json" \
  -d '{"AET": "MY_AET", "Host": "192.168.1.100", "Port": 4242}'

# Test connectivity
curl -X POST http://localhost:8041/modalities/MY_PACS/echo \
  -u orthanc_admin:YOUR_PASSWORD

# Delete a destination
curl -X DELETE http://localhost:8041/modalities/MY_PACS \
  -u orthanc_admin:YOUR_PASSWORD
```

## Configuration

All settings are in `.env` (created by `make setup`):

```bash
# Storage paths
DICOM_STORAGE=/opt/orthanc/orthanc-storage
POSTGRES_STORAGE=/opt/orthanc/postgres-data

# DICOM settings
ORTHANC_AET=ORTHANC_LPCH
DICOM_PORT=4242

# Web ports
OPERATOR_UI_PORT=8040
ORTHANC_WEB_PORT=8041
OHIF_PORT=8042
POSTGRES_PORT=8043

# Credentials
ORTHANC_USERNAME=orthanc_admin
ORTHANC_PASSWORD=helloaide123
POSTGRES_PASSWORD=<generated>

# Timezone
TZ=America/Los_Angeles
```

To change configuration after setup:
1. Edit `.env`
2. Run `make restart`

## Uninstall

To completely remove Orthanc including all data:

```bash
make uninstall
```

This will:
- Stop and remove all Docker containers
- Delete the `.env` configuration
- Delete DICOM storage directory
- Delete PostgreSQL data directory

**You must type "yes" to confirm.**

To just remove containers but keep data:
```bash
make clean
```

## File Structure

```
orthanc/
├── docker-compose.yml      # Service definitions
├── .env                    # Your configuration (generated)
├── setup.sh                # Setup wizard
├── orthanc                 # CLI tool
├── Makefile                # Common operations
│
├── config/
│   ├── orthanc.json        # Orthanc settings
│   ├── nginx.conf          # OHIF proxy
│   └── env.template        # Config template
│
├── ui/
│   ├── index.html          # Operator dashboard
│   └── nginx.conf          # Dashboard proxy
│
├── lua-scripts/
│   └── *.lua               # Routing logic
│
├── init/
│   └── 001_routing_state.sql  # DB schema
│
└── data/                   # Persistent data (if using local paths)
    ├── dicom/              # DICOM files
    └── postgres/           # Database
```

## Troubleshooting

### Services won't start

```bash
# Check logs
docker compose logs

# Check specific service
docker compose logs orthanc

# Check if ports are in use
lsof -i :8040 -i :8041 -i :8042 -i :4242
```

### Database connection issues

```bash
# Check database is ready
docker compose logs orthanc-db

# Should show "ready to accept connections"
```

### DICOM destination unreachable

```bash
# Test from Orthanc container
./orthanc shell
ping DESTINATION_IP

# Or test with netcat
nc -zv DESTINATION_IP PORT
```

### Permission issues with storage

```bash
# DICOM storage should be owned by UID 1000
sudo chown -R 1000:1000 /path/to/dicom/storage

# PostgreSQL storage should be owned by UID 999
sudo chown -R 999:999 /path/to/postgres/storage
```

### Reset everything and start fresh

```bash
# Keep data, reset config
make reset
make setup

# Or completely start over
make uninstall
make setup
```

## Pre-configured DICOM Destinations

Your original modalities (can be managed via UI):

| Name | AE Title | Host | Port |
|------|----------|------|------|
| MERCURE | orthanc | 172.17.0.1 | 11112 |
| LPCHROUTER | LPCHROUTER | 10.50.133.21 | 4000 |
| LPCHTROUTER | LPCHTROUTER | 10.50.130.114 | 4000 |
| MODLINK | PSRTBONEAPP01 | 10.251.201.59 | 104 |

## License

See LICENSE file.
