# Storage Paths Fix - Technical Documentation

## Problem

When installing Orthanc with a custom storage path (e.g., `./install_orthanc.sh /nfs-share/data`), the path information was not preserved for future updates. This caused the `./orthanc-manager.sh update` command to fail with:

```
Error: no such file or directory: /opt/orthanc/orthanc-storage
⚠️  Could not merge JSON: Expecting property name enclosed in double quotes
```

## Root Causes

### 1. Storage Path Not Saved
- Installation script correctly used custom paths but didn't save them
- Update script tried to detect paths from `docker-compose.yml`
- Repository's `docker-compose.yml` had default paths
- Update would overwrite deployed config with wrong paths

### 2. JSON Comments Issue
- `orthanc.json` had JavaScript-style comments (`//`)
- Python's `json.load()` in merge function couldn't parse them
- Update would fail during config merging

## Solution

### Storage Path Preservation

**New File: `/opt/orthanc/.storage_paths`**

This file is created during installation and preserved during updates:

```bash
# Orthanc Storage Paths Configuration
# This file is used by orthanc-manager.sh to preserve storage locations during updates
DICOM_STORAGE_PATH=/nfs-share/data
POSTGRES_DATA_PATH=/opt/orthanc/postgres-data
```

**Installation Flow:**
1. User runs: `./install_orthanc.sh /nfs-share/data`
2. Install script creates directories
3. Updates `docker-compose.yml` with actual paths
4. **Saves paths to `.storage_paths` file** ← NEW
5. Deploys to `/opt/orthanc/`

**Update Flow:**
1. User edits config in repo, runs: `./orthanc-manager.sh update`
2. Update script reads `.storage_paths` file ← NEW (most reliable)
3. Falls back to parsing `docker-compose.yml` if needed
4. Uses detected paths to update new `docker-compose.yml`
5. **Recreates `.storage_paths` with current values** ← NEW
6. Deploys updated config

### JSON Cleanup

Removed all JavaScript-style comments from `orthanc.json`:
- Before: `"Name": "Orthanc",  // Basic server configuration`
- After: `"Name": "Orthanc",`

This ensures Python's `json.load()` can parse the file during config merging.

## Changes Made

### 1. `install-orthanc.sh`
```bash
# Added after setting up docker-compose.yml and orthanc.json
cat > "$LOCAL_INSTALL_DIR/.storage_paths" << EOF
# Orthanc Storage Paths Configuration
DICOM_STORAGE_PATH=$DICOM_STORAGE_DIR
POSTGRES_DATA_PATH=$LOCAL_INSTALL_DIR/postgres-data
EOF
```

### 2. `orthanc-manager.sh`

**Updated detection functions:**
```bash
detect_dicom_storage_path() {
    # 1. Try .storage_paths file (most reliable)
    # 2. Fall back to docker-compose.yml
    # 3. Final fallback to default
}
```

**Updated backup functions:**
- `backup_config()` - now backs up `.storage_paths`
- `create_backup()` - now backs up `.storage_paths`

**Updated restore function:**
- `restore_from_path()` - now restores `.storage_paths`

**Updated update function:**
- Reads current paths from `.storage_paths`
- Uses them to update `docker-compose.yml`
- Recreates `.storage_paths` with current values
- All paths are preserved across updates

**Updated validation:**
- Checks for `.storage_paths` existence
- Warns if missing but continues (uses fallback detection)

### 3. `orthanc.json`
- Removed all `//` comments
- Now valid JSON for Python parsing
- Preserves all functionality

## Usage Examples

### Fresh Installation with Custom Path
```bash
cd /opt/projects/orthanc
./install_orthanc.sh /nfs-share/data

# Result:
# - DICOM files stored at: /nfs-share/data
# - PostgreSQL data at: /opt/orthanc/postgres-data
# - Paths saved to: /opt/orthanc/.storage_paths
```

### Update After Custom Installation
```bash
cd /opt/projects/orthanc
nano orthanc.json  # Make changes
./orthanc-manager.sh update

# Process:
# 1. Reads /opt/orthanc/.storage_paths
# 2. Detects paths: /nfs-share/data and /opt/orthanc/postgres-data
# 3. Updates docker-compose.yml with correct paths
# 4. Preserves paths in updated .storage_paths
# 5. Services restart with correct storage locations
```

### Migration from Old Installation

If you have an existing installation without `.storage_paths`:

```bash
# On the remote server, manually create the file:
cat > /opt/orthanc/.storage_paths << EOF
# Orthanc Storage Paths Configuration
DICOM_STORAGE_PATH=/nfs-share/data
POSTGRES_DATA_PATH=/opt/orthanc/postgres-data
EOF
chmod 600 /opt/orthanc/.storage_paths

# Now updates will work correctly:
./orthanc-manager.sh update
```

## Testing

### Test 1: Fresh Install with Custom Path
```bash
./install_orthanc.sh /custom/path
# Verify .storage_paths contains correct path
cat /opt/orthanc/.storage_paths
```

### Test 2: Update Preserves Paths
```bash
# Make a config change
nano orthanc.json
./orthanc-manager.sh update
# Verify paths unchanged
cat /opt/orthanc/.storage_paths
docker compose config | grep device:
```

### Test 3: Fallback Detection Works
```bash
# Temporarily remove .storage_paths
mv /opt/orthanc/.storage_paths /tmp/
./orthanc-manager.sh validate
# Should detect paths from docker-compose.yml
# Restore file
mv /tmp/.storage_paths /opt/orthanc/
```

## Benefits

1. **Reliable Updates**: Paths are always correct, even after multiple updates
2. **Flexible Storage**: Users can specify any storage location during install
3. **Network Storage**: Works with NFS, CIFS, or any mounted storage
4. **Multiple Servers**: Each server can have different paths
5. **Disaster Recovery**: Paths are included in backups
6. **No Manual Edits**: Users don't need to edit repository files

## Files Affected

| File | Change | Reason |
|------|--------|--------|
| `install-orthanc.sh` | Added `.storage_paths` creation | Save paths at install time |
| `orthanc-manager.sh` | Updated detection, backup, restore | Read and preserve paths |
| `orthanc.json` | Removed `//` comments | Enable JSON parsing |
| `docker-compose.yml` | Reverted to defaults | Template, not deployment config |

## Backward Compatibility

- Old installations without `.storage_paths` still work
- Detection falls back to parsing `docker-compose.yml`
- First update will create `.storage_paths` automatically
- No manual intervention required

## Future Improvements

Possible enhancements:
1. Add storage path migration command
2. Validate paths exist before update
3. Support changing paths via manager script
4. Add path usage statistics
5. Warn if network storage is unmounted

## Troubleshooting

### Update fails with path errors
```bash
# Check if .storage_paths exists
ls -la /opt/orthanc/.storage_paths

# If missing, recreate manually:
cat > /opt/orthanc/.storage_paths << EOF
DICOM_STORAGE_PATH=/your/actual/path
POSTGRES_DATA_PATH=/opt/orthanc/postgres-data
EOF
```

### Validate current configuration
```bash
./orthanc-manager.sh validate
./orthanc-manager.sh usage
```

### Check what paths are being used
```bash
# From repository
cd /opt/projects/orthanc
./orthanc-manager.sh validate

# Output will show:
# DICOM Storage: /nfs-share/data (or wherever configured)
# PostgreSQL Data: /opt/orthanc/postgres-data
```

## Documentation Updates Needed

- [x] Create this technical doc
- [ ] Update README.md troubleshooting section
- [ ] Update MIGRATION_GUIDE.md with .storage_paths info
- [ ] Update SETUP_INSTRUCTIONS.md with new file info
- [ ] Add example to EXAMPLE_UPDATE.md

---

**Version**: 1.0  
**Date**: October 16, 2025  
**Status**: Implemented and Tested

