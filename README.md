# Orthanc DICOM Server - Production Setup

Enterprise-grade DICOM server with PostgreSQL backend, automated management, and safe configuration updates.

[![Status](https://img.shields.io/badge/status-production--ready-green)]()
[![Updated](https://img.shields.io/badge/updated-Oct%202025-blue)]()

---

## 🚀 Quick Start

```bash
# Clone or navigate to this repository
cd /opt/projects/orthanc

# Make scripts executable
chmod +x install-orthanc.sh orthanc-manager.sh

# Install Orthanc (specify your DICOM storage location)
./install-orthanc.sh /data

# Access your installation
# Web UI: http://localhost:8042
# OHIF Viewer: http://localhost:8008
# Default credentials: orthanc_admin / helloaide123
```

**That's it!** Orthanc is running with PostgreSQL backend and your DICOM files stored at `/data`.

---

## 📋 Table of Contents

- [Architecture](#-architecture)
- [Daily Operations](#-daily-operations)
- [Configuration Updates](#-configuration-updates)
- [Backup & Recovery](#-backup--recovery)
- [Management Commands](#-management-commands)
- [Documentation](#-documentation)
- [Troubleshooting](#-troubleshooting)

---

## 🏗️ Architecture

```
Repository: /opt/projects/orthanc/     Installation: /opt/orthanc/        Storage: /data/
├── install-orthanc.sh                 ├── orthanc.json (deployed)        └── DICOM files
├── orthanc-manager.sh                 ├── docker-compose.yml             
├── orthanc.json (template)            ├── .db_password                   
├── docker-compose.yml (template)      ├── postgres-data/                 
├── nginx.conf                         ├── lua-scripts/                   
├── lua-scripts/                       └── backups/                       
└── docs/                              
    ├── UPDATE_GUIDE.md               ← Repo (edit here)  → Deploy → Installation → Storage
    ├── EXAMPLE_UPDATE.md                You work here         Managed         Never touched
    └── ...                          
```

### Key Concepts

- **Repository** (`/opt/projects/orthanc`): Your working directory - edit configs here
- **Installation** (`/opt/orthanc`): Running system - managed by scripts
- **Storage** (`/data`): DICOM files - preserved during all operations

**All commands run from the repository directory!**

---

## 💻 Daily Operations

### Check Status

```bash
cd /opt/projects/orthanc
./orthanc-manager.sh status
```

### View Logs

```bash
./orthanc-manager.sh logs         # Follow mode (Ctrl+C to exit)
docker compose logs orthanc       # Orthanc only
```

### Restart Services

```bash
./orthanc-manager.sh restart
```

### Check Disk Usage

```bash
./orthanc-manager.sh usage
```

---

## 🔧 Configuration Updates

### ✨ Safe Update Process (NEW!)

Updates now automatically preserve:
- ✅ Database passwords
- ✅ DICOM modalities
- ✅ User accounts
- ✅ Storage paths
- ✅ All your data

### How to Update

```bash
cd /opt/projects/orthanc

# 1. Edit configuration
nano orthanc.json
# Make your changes (add modalities, tune performance, etc.)

# 2. Optional: Commit changes
git add orthanc.json
git commit -m "Added NEW_PACS modality"

# 3. Deploy update
./orthanc-manager.sh update

# Done! Services restart with new config (~30 seconds)
```

### Common Updates

**Add DICOM Modality:**
```json
"DicomModalities" : {
    "EXISTING" : [ "AET", "10.0.0.1", 104 ],
    "NEW_PACS" : [ "NEW_AET", "192.168.1.100", 104 ]
}
```

**Tune Performance:**
```json
"ConcurrentJobs" : 4,
"HttpThreadsCount" : 100,
"MaximumStorageSize" : 500000
```

**Update Lua Scripts:**
```bash
nano lua-scripts/autosend_leg_length.lua
./orthanc-manager.sh update
```

See [docs/EXAMPLE_UPDATE.md](docs/EXAMPLE_UPDATE.md) for detailed scenarios.

---

## 💾 Backup & Recovery

### Create Backup

```bash
cd /opt/projects/orthanc
./orthanc-manager.sh backup
```

**Includes:**
- Configuration files (with real passwords)
- PostgreSQL database dump (SQL format)
- PostgreSQL data directory
- DICOM storage (all files)
- Metadata and timestamps

**Location:** `/opt/orthanc/backups/full_backup_YYYYMMDD_HHMMSS/`

### Restore from Backup

```bash
./orthanc-manager.sh restore

# Select backup from list
# Choose SQL dump for faster restore (recommended)
```

### Automatic Backups

Backups are created automatically:
- ✅ Before every update
- ✅ Before reinstallation
- ✅ Before purge operations

### Clean Old Backups

```bash
./orthanc-manager.sh clean    # Keeps 5 most recent
```

---

## 🎮 Management Commands

All commands run from `/opt/projects/orthanc`:

### Service Management
```bash
./orthanc-manager.sh start      # Start services
./orthanc-manager.sh stop       # Stop services
./orthanc-manager.sh restart    # Restart services
./orthanc-manager.sh status     # Show status & URLs
./orthanc-manager.sh logs       # View logs (follow mode)
```

### Configuration & Updates
```bash
./orthanc-manager.sh update     # Deploy configuration changes
./orthanc-manager.sh validate   # Health check before update
```

### Backup & Restore
```bash
./orthanc-manager.sh backup     # Create full backup
./orthanc-manager.sh restore    # Restore from backup
./orthanc-manager.sh clean      # Clean old backups
```

### Monitoring
```bash
./orthanc-manager.sh usage      # Disk usage & paths
./orthanc-manager.sh disk       # Alias for usage
```

### Storage Management
```bash
./orthanc-manager.sh migrate    # Move DICOM storage
```

### Removal (Use with caution)
```bash
./orthanc-manager.sh delete     # Remove containers, keep data
./orthanc-manager.sh purge      # Complete removal (creates backup)
```

---

## 📚 Documentation

Comprehensive guides in the `docs/` folder:

| Document | Purpose |
|----------|---------|
| **[SETUP_INSTRUCTIONS.md](docs/SETUP_INSTRUCTIONS.md)** | Complete setup guide and verification |
| **[EXAMPLE_UPDATE.md](docs/EXAMPLE_UPDATE.md)** | Step-by-step update examples |
| **[UPDATE_GUIDE.md](docs/UPDATE_GUIDE.md)** | Detailed update procedures & best practices |
| **[MIGRATION_GUIDE.md](docs/MIGRATION_GUIDE.md)** | Migrating existing installations |
| **[IMPLEMENTATION_SUMMARY.md](docs/IMPLEMENTATION_SUMMARY.md)** | What was fixed and why |
| **[CHANGELOG_2025.md](docs/CHANGELOG_2025.md)** | Technical changelog |

---

## 🔒 Security

### Default Credentials
- **Username:** `orthanc_admin`
- **Password:** `helloaide123`

**⚠️ Change these immediately in production!**

Edit `orthanc.json`:
```json
"RegisteredUsers" : {
    "your_username": "your_secure_password"
}
```

Then run: `./orthanc-manager.sh update`

### Database Password
- Automatically generated during installation
- Stored securely in `/opt/orthanc/.db_password` (chmod 600)
- Never exposed in templates or logs
- Preserved during all updates

### Network Ports
- **8042**: Orthanc Web UI & API
- **8008**: OHIF Viewer
- **4242**: DICOM protocol
- **5433**: PostgreSQL (localhost only)

Configure firewall rules as needed for your network.

---

## 🐛 Troubleshooting

### Services Won't Start

```bash
cd /opt/projects/orthanc

# Check logs
./orthanc-manager.sh logs

# Validate installation
./orthanc-manager.sh validate

# Restore from backup if needed
./orthanc-manager.sh restore
```

### Can't Access Web UI

```bash
# Check if services are running
./orthanc-manager.sh status

# Test connectivity
curl http://localhost:8042

# Check container logs
docker compose logs orthanc
```

### Update Failed

```bash
# Automatic backup was created - restore it
./orthanc-manager.sh restore

# Select the most recent backup
# Services will restart with previous config
```

### Database Connection Issues

```bash
# Verify password consistency
cat /opt/orthanc/.db_password
grep "Password" /opt/orthanc/orthanc.json

# If they don't match, restore from backup
./orthanc-manager.sh restore
```

### Storage Issues

```bash
# Check storage paths and usage
./orthanc-manager.sh usage

# Verify /data is accessible
ls -la /data

# Check available space
df -h /data
```

---

## 🔍 Health Check

Run this anytime to verify your setup:

```bash
cd /opt/projects/orthanc
./orthanc-manager.sh validate
```

**Checks:**
- ✅ Database credentials exist
- ✅ DICOM storage accessible
- ✅ PostgreSQL data accessible
- ✅ Services running
- ✅ Configuration valid

---

## 📊 Service URLs

After installation, access:

| Service | URL | Purpose |
|---------|-----|---------|
| **Orthanc Web UI** | http://localhost:8042 | Upload/manage DICOM files |
| **OHIF Viewer** | http://localhost:8008 | View medical images |
| **DICOM Protocol** | Port 4242 | Receive from modalities |
| **PostgreSQL** | localhost:5433 | Database (internal) |

---

## 🎯 Common Workflows

### Initial Setup

```bash
cd /opt/projects/orthanc
./install-orthanc.sh /data
# Wait for installation (~2 minutes)
# Access http://localhost:8042
```

### Adding a DICOM Modality

```bash
cd /opt/projects/orthanc
nano orthanc.json               # Add to DicomModalities
./orthanc-manager.sh update     # Deploy
```

### Performance Tuning

```bash
nano orthanc.json               # Update ConcurrentJobs, threads, etc.
./orthanc-manager.sh update
```

### Updating Lua Scripts

```bash
nano lua-scripts/my_script.lua
./orthanc-manager.sh update
```

### Weekly Backup

```bash
./orthanc-manager.sh backup
./orthanc-manager.sh clean      # Remove old backups
```

### Version Upgrade

```bash
nano docker-compose.yml         # Update image version
./orthanc-manager.sh update     # Deploy new version
```

---

## 🌟 What Makes This Special

### Safe Configuration Updates
- ✅ **Password Preservation**: Database credentials never lost
- ✅ **Smart Merging**: DICOM modalities and users preserved
- ✅ **Pre-validation**: Catches issues before making changes
- ✅ **Automatic Backups**: Safety net always available
- ✅ **Idempotent**: Safe to re-run operations

### Enterprise Features
- ✅ PostgreSQL backend for reliability
- ✅ Configurable storage location
- ✅ Comprehensive backup/restore
- ✅ OHIF viewer integration
- ✅ Lua scripting support
- ✅ Production-ready security

### Developer-Friendly
- ✅ Version control compatible
- ✅ Clear separation of concerns
- ✅ Comprehensive documentation
- ✅ Easy rollback capability
- ✅ Detailed logging

---

## 📦 Repository Structure

```
/opt/projects/orthanc/
├── README.md                      ← You are here
├── install-orthanc.sh             ← Initial installation script
├── orthanc-manager.sh             ← Management script (all operations)
├── orthanc.json                   ← Orthanc configuration (template)
├── docker-compose.yml             ← Docker services (template)
├── nginx.conf                     ← OHIF proxy configuration
├── lua-scripts/                   ← Automation scripts
│   └── autosend_leg_length.lua
└── docs/                          ← Detailed documentation
    ├── SETUP_INSTRUCTIONS.md      ← Complete setup guide
    ├── EXAMPLE_UPDATE.md          ← Real-world examples
    ├── UPDATE_GUIDE.md            ← Update procedures
    ├── MIGRATION_GUIDE.md         ← Existing installation migration
    ├── IMPLEMENTATION_SUMMARY.md  ← What was fixed
    └── CHANGELOG_2025.md          ← Technical changes
```

---

## 🆘 Getting Help

### Check These First
1. **Status**: `./orthanc-manager.sh status`
2. **Logs**: `./orthanc-manager.sh logs`
3. **Validation**: `./orthanc-manager.sh validate`
4. **Documentation**: See `docs/` folder

### Common Issues

| Issue | Solution |
|-------|----------|
| Services won't start | Check logs, validate, restore backup |
| Can't access web UI | Verify port 8042 not blocked |
| Update failed | Restore from automatic backup |
| DICOM files missing | Check `./orthanc-manager.sh usage` |

---

## 🚦 Quick Reference Card

```bash
# Setup (one time)
cd /opt/projects/orthanc
./install-orthanc.sh /data

# Daily operations
./orthanc-manager.sh status    # Check health
./orthanc-manager.sh logs      # View activity

# Make changes
nano orthanc.json              # Edit config
./orthanc-manager.sh update    # Deploy safely

# Backup & recovery
./orthanc-manager.sh backup    # Create backup
./orthanc-manager.sh restore   # Restore if needed

# Troubleshooting
./orthanc-manager.sh validate  # Health check
./orthanc-manager.sh usage     # Disk usage
docker compose logs orthanc    # Detailed logs
```

---

## 📄 License & Credits

This setup framework is designed for medical imaging workflows requiring:
- Enterprise reliability
- Safe configuration management
- Data integrity
- Easy disaster recovery

**Key Technologies:**
- [Orthanc](https://www.orthanc-server.com/) - Open-source DICOM server
- [PostgreSQL](https://www.postgresql.org/) - Reliable database backend
- [OHIF Viewer](https://ohif.org/) - Web-based medical image viewer
- [Docker](https://www.docker.com/) - Containerization platform

---

## ✅ System Requirements

- **OS**: Linux (tested on Ubuntu 20.04+)
- **Docker**: 20.10+
- **Docker Compose**: 2.0+
- **Disk Space**: 
  - Installation: ~500MB
  - Storage: As needed for DICOM files
- **Memory**: 2GB minimum, 4GB recommended
- **Python**: 3.6+ (optional, for smart config merging)

---

## 🎉 Ready to Start?

```bash
# 1. Navigate to repository
cd /opt/projects/orthanc

# 2. Make scripts executable
chmod +x install-orthanc.sh orthanc-manager.sh

# 3. Install
./install-orthanc.sh /data

# 4. Access your DICOM server
open http://localhost:8042
```

**Need help?** Check the `docs/` folder for detailed guides!

---

**Last Updated**: October 2025  
**Status**: Production Ready ✅  
**Documentation**: Comprehensive ✅  
**Safe Updates**: Enabled ✅
