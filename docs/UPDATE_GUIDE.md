# Orthanc Update & Configuration Management Guide

## 🎉 What's Been Fixed

Your Orthanc installation now safely handles configuration updates while preserving all data and settings!

### Critical Issues Resolved

1. **✅ Password Preservation During Updates**
   - Previously: Updates would overwrite `orthanc.json` with template password `ChangePasswordHere`, breaking database connection
   - Now: Database passwords are automatically retrieved and preserved during updates

2. **✅ Configuration Merge Support**
   - Previously: All manual configuration changes (DICOM modalities, user accounts) were lost during updates
   - Now: Dynamic settings are intelligently merged, preserving your customizations

3. **✅ Idempotent Installation**
   - Previously: Running `install-orthanc.sh` again would break existing installations
   - Now: Script detects existing installations and guides you to use the update process

4. **✅ Pre-Update Validation**
   - New validation checks ensure update safety before making any changes
   - Verifies database credentials, data accessibility, and service status

5. **✅ Enhanced Backup System**
   - Database dumps now included in backups for faster, more reliable restoration
   - Backup metadata tracks storage paths and versions

## 🚀 How to Update Configuration Safely

### Method 1: Using the Update Command (Recommended)

```bash
# Make changes to your configuration files in the repo
cd /dataNAS/people/arogya/projects/orthanc

# Run the update command
cd /opt/orthanc
./orthanc-manager.sh update
```

**What happens during update:**
1. ✅ Validates prerequisites (credentials, data paths)
2. ✅ Creates automatic backup
3. ✅ Retrieves existing database password
4. ✅ Copies new configuration files
5. ✅ Restores database credentials
6. ✅ Preserves storage paths
7. ✅ Merges dynamic settings (modalities, users)
8. ✅ Restarts services with new configuration

### Method 2: Manual Configuration Changes

For small changes that don't require repo updates:

```bash
cd /opt/orthanc

# Edit configuration directly
nano orthanc.json

# Restart services to apply changes
./orthanc-manager.sh restart
```

## 📋 Safe Update Workflow

### Example: Adding a New DICOM Modality

**Step 1:** Update configuration in your repo
```bash
cd /dataNAS/people/arogya/projects/orthanc
nano orthanc.json

# Add your new modality to DicomModalities section
"DicomModalities" : {
    "MERCURE" : [ "orthanc", "172.17.0.1", 11112 ],
    "NEW_DEVICE" : [ "DEVICE_AET", "192.168.1.100", 104 ]
}
```

**Step 2:** Run update
```bash
cd /opt/orthanc
./orthanc-manager.sh update
```

**Result:** 
- ✅ New configuration applied
- ✅ Existing modalities preserved (if added via Orthanc UI)
- ✅ Database password maintained
- ✅ No data loss
- ✅ Automatic backup created

### Example: Modifying Performance Settings

```bash
cd /dataNAS/people/arogya/projects/orthanc
nano orthanc.json

# Update settings like:
"ConcurrentJobs" : 4,
"HttpThreadsCount" : 100,
"MaximumStorageSize" : 500000,

# Apply update
cd /opt/orthanc
./orthanc-manager.sh update
```

## 🔍 Validation & Troubleshooting

### Check System Status Before Update

```bash
cd /opt/orthanc
./orthanc-manager.sh validate
```

This checks:
- ✅ Database credentials exist
- ✅ DICOM storage is accessible
- ✅ PostgreSQL data directory exists
- ✅ Services are running

### View Current Storage Paths

```bash
cd /opt/orthanc
./orthanc-manager.sh usage
```

Shows:
- Storage locations
- Disk usage
- File counts
- Network mount status

## 💾 Backup & Restore

### Create Full Backup (Recommended Before Major Changes)

```bash
cd /opt/orthanc
./orthanc-manager.sh backup
```

**What's included:**
- Configuration files (docker-compose.yml, orthanc.json, nginx.conf)
- Database credentials (.db_password)
- PostgreSQL database dump (SQL format, compressed)
- PostgreSQL data directory (full copy)
- DICOM storage (all files)
- Lua scripts
- Backup metadata (paths, versions, timestamps)

**Backup location:** `/opt/orthanc/backups/full_backup_YYYYMMDD_HHMMSS/`

### Restore from Backup

```bash
cd /opt/orthanc
./orthanc-manager.sh restore
```

You'll be presented with available backups and can choose restoration method:
- **SQL dump restore** (faster, cleaner)
- **Data directory restore** (traditional method)

## 🛡️ Protection Mechanisms

### Installation Protection

Running `install-orthanc.sh` on an existing installation now:
1. Detects existing installation
2. Shows you three options:
   - Keep existing (recommended)
   - Reinstall (with strong warnings)
   - Cancel
3. Creates backup if you proceed with reinstall

### Update Protection

The update process:
1. Validates before making changes
2. Creates automatic backup
3. Aborts if critical files missing (e.g., .db_password)
4. Preserves storage paths
5. Maintains database connectivity

### Configuration Merge

When updating, these settings are preserved from your running system:
- `DicomModalities` - DICOM destinations
- `RegisteredUsers` - User accounts
- `OrthancPeers` - Connected Orthanc instances

New settings from the template are applied, existing dynamic data is kept.

## 📝 Best Practices

### 1. Always Backup Before Major Changes
```bash
./orthanc-manager.sh backup
```

### 2. Test Configuration Changes
After updating, verify services are working:
```bash
./orthanc-manager.sh status
curl http://localhost:8042
```

### 3. Keep Configuration in Version Control
Your repo at `/dataNAS/people/arogya/projects/orthanc` should be your source of truth for:
- `orthanc.json` structure and default values
- `docker-compose.yml` service definitions
- `nginx.conf` proxy configuration
- Lua scripts

### 4. Clean Old Backups Periodically
```bash
./orthanc-manager.sh clean
```
Keeps 5 most recent backups, removes older ones.

### 5. Monitor Disk Usage
```bash
./orthanc-manager.sh usage
```

## 🔧 Common Scenarios

### Scenario 1: Update Orthanc to New Version

```bash
cd /dataNAS/people/arogya/projects/orthanc
nano docker-compose.yml
# Change: image: jodogne/orthanc-python to image: jodogne/orthanc-python:latest

cd /opt/orthanc
./orthanc-manager.sh update
```

### Scenario 2: Add New Lua Script

```bash
cd /dataNAS/people/arogya/projects/orthanc/lua-scripts
nano new_script.lua
# Write your script

cd /opt/orthanc
./orthanc-manager.sh update
```

### Scenario 3: Change Configuration Parameter

```bash
cd /dataNAS/people/arogya/projects/orthanc
nano orthanc.json
# Update parameter

cd /opt/orthanc
./orthanc-manager.sh update
```

### Scenario 4: Migrate to New Storage Location

```bash
cd /opt/orthanc
./orthanc-manager.sh migrate
# Follow prompts to specify new location
```

## 🆘 Recovery Procedures

### If Update Fails

1. Check logs:
   ```bash
   ./orthanc-manager.sh logs
   ```

2. Restore from automatic backup:
   ```bash
   ./orthanc-manager.sh restore
   # Select the most recent backup
   ```

### If Services Won't Start

1. Validate configuration:
   ```bash
   ./orthanc-manager.sh validate
   ```

2. Check service status:
   ```bash
   docker compose ps
   docker compose logs
   ```

3. Restore from backup if needed

### If Database Connection Lost

This should not happen with the new update system, but if it does:

```bash
# Check if password file exists
cat /opt/orthanc/.db_password

# Verify password matches in both files
grep "Password" /opt/orthanc/orthanc.json
grep "POSTGRES_PASSWORD" /opt/orthanc/docker-compose.yml
```

## 📚 Command Reference

```bash
./orthanc-manager.sh start      # Start services
./orthanc-manager.sh stop       # Stop services
./orthanc-manager.sh restart    # Restart services
./orthanc-manager.sh status     # Show status
./orthanc-manager.sh logs       # View logs
./orthanc-manager.sh update     # Update configuration
./orthanc-manager.sh backup     # Create backup
./orthanc-manager.sh restore    # Restore from backup
./orthanc-manager.sh validate   # Validate installation
./orthanc-manager.sh usage      # Show disk usage
./orthanc-manager.sh clean      # Clean old backups
./orthanc-manager.sh migrate    # Migrate storage
./orthanc-manager.sh delete     # Remove containers (keep data)
./orthanc-manager.sh purge      # Complete removal
```

## ✨ Summary

Your Orthanc installation now has:
- ✅ **Safe updates** - No more password issues
- ✅ **Configuration preservation** - Your settings are kept
- ✅ **Smart merging** - New features + your customizations
- ✅ **Enhanced backups** - Database dumps included
- ✅ **Validation checks** - Catches problems early
- ✅ **Idempotent installation** - Safe to re-run scripts

**You can now confidently update your Orthanc configuration without fear of data loss or broken connections!** 🎉

