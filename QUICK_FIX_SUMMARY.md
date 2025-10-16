# Quick Fix Summary - Storage Paths & Update Issues

## What Was Fixed

### 1. ✅ Storage Path Preservation
**Problem**: Updates broke because custom storage paths (like `/nfs-share/data`) weren't saved anywhere.

**Solution**: Created `.storage_paths` file in `/opt/orthanc/` that stores:
```bash
DICOM_STORAGE_PATH=/nfs-share/data
POSTGRES_DATA_PATH=/opt/orthanc/postgres-data
```

### 2. ✅ JSON Parsing Error
**Problem**: `orthanc.json` had JavaScript comments (`//`) that Python couldn't parse.

**Solution**: Removed all comments, made it valid JSON.

### 3. ✅ Added Detailed Logging
**Problem**: Hard to track post-processing reroutes from MERCURE.

**Solution**: Added comprehensive logging to `autosend_leg_length.lua`:
- Instance details (ID, Series Description, Modality, etc.)
- Routing decisions (QA Visualization vs SR)
- Send operation results with Job IDs
- Success/failure indicators

## What Changed

### For Your Remote Server

When you run `./orthanc-manager.sh update` now, it will:
1. Read `/opt/orthanc/.storage_paths` to get the correct paths
2. Use those paths (like `/nfs-share/data`) instead of defaults
3. Update configs correctly
4. Preserve paths for next update

### Files Modified

| File | What Changed |
|------|-------------|
| `install-orthanc.sh` | Now saves storage paths to `.storage_paths` |
| `orthanc-manager.sh` | Reads `.storage_paths`, preserves paths during updates |
| `orthanc.json` | Removed `//` comments for valid JSON |
| `lua-scripts/autosend_leg_length.lua` | Added detailed POST-PROCESSING logs |
| `docker-compose.yml` | Reverted to template defaults (gets updated at install) |

## What You Need to Do

### Option 1: For Existing Installation (Recommended)

SSH to your remote server and create the missing file:

```bash
# Create the storage paths file
cat > /opt/orthanc/.storage_paths << 'EOF'
# Orthanc Storage Paths Configuration
DICOM_STORAGE_PATH=/nfs-share/data
POSTGRES_DATA_PATH=/opt/orthanc/postgres-data
EOF

chmod 600 /opt/orthanc/.storage_paths
```

Then from your local machine:
```bash
cd /dataNAS/people/arogya/projects/orthanc
./orthanc-manager.sh update
```

### Option 2: Test on Local First

If you're unsure about the paths, test locally first:
```bash
# This will show you what paths it detects
./orthanc-manager.sh validate
./orthanc-manager.sh usage
```

## Verification

After the fix, you should see:
```bash
./orthanc-manager.sh update

# Output should show:
✅ Storage paths configuration found
Current storage paths:
  • DICOM: /nfs-share/data
  • PostgreSQL: /opt/orthanc/postgres-data
✅ Storage paths preserved
```

## New Logging Output

In Orthanc logs, you'll now see detailed POST-PROCESSING messages:

```
POST-PROCESSING: Analyzing instance abc123
   Series Description: QA Visualization
   Modality: SC
   Instance Number: 1
   SOP Instance UID: 1.2.3.4.5...
POST-PROCESSING: Detected QA Visualization - routing to LPCHROUTER and LPCHTROUTER
   ✓ Successfully sent to LPCHROUTER (Job: 12345)
   ✓ Successfully sent to LPCHTROUTER (Job: 12346)
   ✓ Instance marked as processed
```

## Documentation

Full technical details in:
- `/docs/STORAGE_PATHS_FIX.md` - Complete technical documentation

## Next Steps

1. Create `.storage_paths` on your server (see Option 1 above)
2. Run update: `./orthanc-manager.sh update`
3. Check logs for new POST-PROCESSING messages
4. Verify everything works correctly

## Questions?

- Check validation: `./orthanc-manager.sh validate`
- Check paths: `./orthanc-manager.sh usage`
- View logs: `./orthanc-manager.sh logs`

---

**Status**: Ready to deploy  
**Date**: October 16, 2025

