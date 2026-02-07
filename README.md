# 🏥 Orthanc PACS

A containerized PACS (Picture Archiving and Communication System) with an operator-friendly dashboard, workflow tracking, and QI dashboards.

## Quick Start

```bash
# 1. Clone repository
git clone <repo>
cd orthanc

# 2. Run setup (interactive wizard)
make setup

# 3. Open dashboard
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

### Custom Configuration

All settings can be configured in `.env`. Start from the defaults template:

```bash
# Copy defaults
cp config/env.defaults .env

# Edit to customize
nano .env

# Apply configuration
make setup
```

## Ports

| Port | Service | Description |
|------|---------|-------------|
| **8040** | Operator Dashboard | Main management interface |
| **8041** | Orthanc | PACS Web UI & REST API |
| **8042** | OHIF Viewer | Clinical image viewer |
| **8043** | PostgreSQL | Database (for tools) |
| **8044** | Routing API | Workflow tracking API |
| **8045** | Grafana | QI Dashboards |
| **4242** | DICOM | DICOM protocol |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           YOUR BROWSER                               │
│                                                                     │
│   :8040         :8041         :8042         :8045                   │
│     │             │             │             │                     │
└─────┼─────────────┼─────────────┼─────────────┼─────────────────────┘
      │             │             │             │
      ▼             ▼             ▼             ▼
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
│ Operator │  │ Orthanc  │  │   OHIF   │  │ Grafana  │
│Dashboard │─▶│   PACS   │◀─│  Viewer  │  │    QI    │
└──────────┘  └────┬─────┘  └──────────┘  └────┬─────┘
                   │                           │
            ┌──────┴──────┐                    │
            │  PostgreSQL │◀───────────────────┘
            └─────────────┘
```

## Configuration

All settings are in `.env`. The file `config/env.defaults` contains all available options with documentation.

### Storage Paths

```bash
DICOM_STORAGE=/opt/orthanc/orthanc-storage
POSTGRES_STORAGE=/opt/orthanc/postgres-data
```

### DICOM Settings

```bash
ORTHANC_AET=ORTHANC_LPCH
DICOM_PORT=4242
```

### Credentials

```bash
ORTHANC_USERNAME=orthanc_admin
ORTHANC_PASSWORD=helloaide123

POSTGRES_USER=orthanc
POSTGRES_PASSWORD=<generated>

GRAFANA_USER=admin
GRAFANA_PASSWORD=admin
```

### DICOM Modalities

Define remote PACS/devices directly in `.env`:

```bash
# Format: MODALITY_<NAME>=<AET>|<HOST>|<PORT>
MODALITY_MERCURE=orthanc|172.17.0.1|11112
MODALITY_LPCHROUTER=LPCHROUTER|10.50.133.21|4000
MODALITY_LPCHTROUTER=LPCHTROUTER|10.50.130.114|4000
MODALITY_MODLINK=PSRTBONEAPP01|10.251.201.59|104

# Add your own:
MODALITY_WORKSTATION=WORKSTATION1|192.168.1.100|4242
```

After editing modalities, apply changes:

```bash
make seed-modalities
```

### Web Ports

```bash
OPERATOR_UI_PORT=8040
ORTHANC_WEB_PORT=8041
OHIF_PORT=8042
POSTGRES_PORT=8043
ROUTING_API_PORT=8044
GRAFANA_PORT=8045
```

## Commands

### Setup & Installation

| Command | Description |
|---------|-------------|
| `make setup` | Interactive setup wizard (safe to re-run) |
| `make quick-setup` | Quick setup with defaults |
| `make menu` | Full interactive menu |

### Service Management

| Command | Description |
|---------|-------------|
| `make start` | Start all services |
| `make stop` | Stop all services |
| `make restart` | Restart all services |
| `make logs` | View logs (Ctrl+C to exit) |
| `make status` | System status |

### Configuration

| Command | Description |
|---------|-------------|
| `make seed-modalities` | Apply modality changes from .env |
| `make rebuild` | Rebuild all Docker images |

### Backup & Restore

| Command | Description |
|---------|-------------|
| `make backup` | Create backup of all data |
| `make backup-list` | List available backups |
| `make restore FILE=<path>` | Restore from backup |

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

### Via .env (Recommended for Initial Setup)

Edit `.env` and add/modify modalities:

```bash
# Format: MODALITY_<NAME>=<AET>|<HOST>|<PORT>
MODALITY_NEWPACS=NEWPACS_AET|192.168.1.50|4242
```

Apply changes:

```bash
make seed-modalities
```

### Via the Web UI

1. Open the Operator Dashboard: http://localhost:8040
2. In the "DICOM Destinations" section, click **+ Add**
3. Fill in Name, AE Title, Host, Port
4. Click **Add** to save

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
```

## Workflow Tracking

The system tracks studies through the processing pipeline:

1. **Study Received** - DICOM arrives at Orthanc
2. **Sent to MERCURE** - Forwarded to AI processing
3. **AI Results Back** - Results returned from MERCURE
4. **Routed to Destinations** - Final delivery to PACS

View workflow status in the Operator Dashboard or Grafana QI dashboards.

## Backup & Restore

### Create a Backup

```bash
make backup
# or with a specific filename
./setup.sh --backup my-backup.tar.gz
```

Backups include:
- DICOM storage
- PostgreSQL database
- Configuration files (.env, orthanc.json)

### Restore from Backup

```bash
make restore FILE=backups/orthanc-backup-2026-02-06.tar.gz
```

### Migrate to New Storage Location

```bash
# 1. Create backup
make backup

# 2. Edit .env with new paths
nano .env

# 3. Run setup to apply
make setup
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
│   ├── env.defaults        # All configuration options (reference)
│   ├── orthanc.json        # Orthanc settings
│   └── nginx.conf          # OHIF proxy
│
├── ui/
│   ├── index.html          # Operator dashboard
│   └── nginx.conf          # Dashboard proxy
│
├── api/
│   ├── app.py              # Routing API
│   └── Dockerfile          # API container
│
├── lua-scripts/
│   └── *.lua               # Routing logic
│
├── grafana/
│   ├── provisioning/       # Datasource config
│   └── dashboards/         # QI dashboard definitions
│
├── init/
│   └── *.sql               # Database schema
│
└── backups/                # Backup files
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

### Disk space issues

```bash
# Check disk usage
df -h

# If root disk is full, migrate to another location:
make backup
# Edit .env with new DICOM_STORAGE and POSTGRES_STORAGE paths
make restore FILE=backups/latest.tar.gz
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

## SSH Port Forwarding

To access services from a remote machine:

```bash
ssh -L 9040:localhost:8040 \
    -L 9041:localhost:8041 \
    -L 9042:localhost:8042 \
    -L 9043:localhost:8043 \
    -L 9044:localhost:8044 \
    -L 9045:localhost:8045 \
    user@server
```

Then access:
- Dashboard: http://localhost:9040
- Orthanc: http://localhost:9041
- OHIF: http://localhost:9042
- Grafana: http://localhost:9045

## License

See LICENSE file.
