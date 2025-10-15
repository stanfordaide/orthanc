# ✅ YES - Already Configured for Repo-Based Operations!

## How It Works

Both scripts use dynamic path detection:

### `orthanc-manager.sh`
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Where script is located
ORTHANC_DIR="/opt/orthanc"  # Where to deploy (hardcoded)
```

### `install-orthanc.sh`
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Where script is located
LOCAL_INSTALL_DIR="/opt/orthanc"  # Where to install (default)
```

**This means:**
- Scripts read source files from **wherever they're located** (your repo)
- Scripts deploy/manage installation at **`/opt/orthanc`** (hardcoded)
- Perfect separation of concerns! ✅

---

## Your Complete Setup

Here's exactly what to do:

### Step 1: Initial Setup (One Time)

```bash
# You already have the repo at:
# /opt/projects/orthanc
#   ├── install-orthanc.sh
#   ├── orthanc-manager.sh
#   ├── orthanc.json
#   ├── docker-compose.yml
#   ├── nginx.conf
#   └── lua-scripts/

# Make scripts executable
cd /opt/projects/orthanc
chmod +x install-orthanc.sh
chmod +x orthanc-manager.sh

# That's it! You're ready.
```

---

## How to Use

### Initial Installation

```bash
# Run from repo directory
cd /opt/projects/orthanc

# Install to /opt/orthanc with data at /data
./install-orthanc.sh /data

# What happens:
# ✅ Reads templates from /opt/projects/orthanc (SCRIPT_DIR)
# ✅ Installs to /opt/orthanc (LOCAL_INSTALL_DIR)
# ✅ Configures storage at /data
# ✅ Generates secure password
# ✅ Starts services
```

---

### Making Updates

```bash
# Always work from repo directory
cd /opt/projects/orthanc

# 1. Edit your configs
nano orthanc.json

# 2. Optional: Commit changes
git add orthanc.json
git commit -m "Updated configuration"

# 3. Deploy update
./orthanc-manager.sh update

# What happens:
# ✅ Reads new configs from /opt/projects/orthanc (SCRIPT_DIR)
# ✅ Validates /opt/orthanc installation
# ✅ Creates backup
# ✅ Preserves passwords and /data path
# ✅ Deploys to /opt/orthanc (ORTHANC_DIR)
# ✅ Restarts services
```

---

### All Management Commands

```bash
# Always from repo directory
cd /opt/projects/orthanc

# Service management
./orthanc-manager.sh start
./orthanc-manager.sh stop
./orthanc-manager.sh restart
./orthanc-manager.sh status
./orthanc-manager.sh logs

# Configuration & updates
./orthanc-manager.sh update     # Deploy changes
./orthanc-manager.sh validate   # Health check

# Backup & restore
./orthanc-manager.sh backup
./orthanc-manager.sh restore

# Monitoring
./orthanc-manager.sh usage      # Disk usage
./orthanc-manager.sh disk       # Alias for usage

# Storage
./orthanc-manager.sh migrate    # Move storage location

# Removal
./orthanc-manager.sh delete     # Remove containers, keep data
./orthanc-manager.sh purge      # Complete removal
```

---

## Directory Structure

```
/opt/projects/orthanc/          ← YOUR WORKING DIRECTORY (repo)
├── install-orthanc.sh          ← Run from here
├── orthanc-manager.sh          ← Run from here
├── orthanc.json                ← Edit this (templates)
├── docker-compose.yml          ← Edit this (templates)
├── nginx.conf                  ← Edit this
├── lua-scripts/                ← Edit these
│   └── autosend_leg_length.lua
├── README.md                   ← Documentation
├── UPDATE_GUIDE.md
├── EXAMPLE_UPDATE.md
└── SETUP_INSTRUCTIONS.md       ← This file

/opt/orthanc/                   ← INSTALLATION (managed by scripts)
├── orthanc.json                ← Deployed (with real password)
├── docker-compose.yml          ← Deployed (with /data path)
├── nginx.conf                  ← Deployed
├── .db_password                ← Generated secret
├── postgres-data/              ← PostgreSQL database
├── lua-scripts/                ← Deployed
│   └── autosend_leg_length.lua
└── backups/                    ← Auto-created backups
    ├── config_backup_TIMESTAMP/
    └── full_backup_TIMESTAMP/

/data/                          ← DICOM STORAGE (configurable)
└── [All your DICOM files]
```

---

## Verification Test

Run this to verify your setup:

```bash
cd /opt/projects/orthanc

echo "🔍 Checking setup..."
echo ""

# Check scripts are executable
if [[ -x install-orthanc.sh ]] && [[ -x orthanc-manager.sh ]]; then
    echo "✅ Scripts are executable"
else
    echo "⚠️  Making scripts executable..."
    chmod +x install-orthanc.sh orthanc-manager.sh
    echo "✅ Scripts now executable"
fi

# Check required files exist
required_files=("orthanc.json" "docker-compose.yml" "nginx.conf")
for file in "${required_files[@]}"; do
    if [[ -f "$file" ]]; then
        echo "✅ $file exists in repo"
    else
        echo "❌ Missing: $file"
    fi
done

# Check lua-scripts directory
if [[ -d "lua-scripts" ]]; then
    echo "✅ lua-scripts/ directory exists"
else
    echo "❌ Missing: lua-scripts/ directory"
fi

# Test script can find files
echo ""
echo "📍 Script will read from: $(pwd)"
echo "📍 Script will deploy to: /opt/orthanc"
echo "📍 DICOM storage at: /data (or as specified)"

# Check if installation exists
echo ""
if [[ -d "/opt/orthanc" ]]; then
    echo "✅ Installation exists at /opt/orthanc"
    ./orthanc-manager.sh status
else
    echo "ℹ️  No installation yet - run: ./install-orthanc.sh /data"
fi

echo ""
echo "🎉 Setup verified! You're ready to use repo-based operations."
```

Save this as `verify-setup.sh` and run:

```bash
cd /opt/projects/orthanc
bash verify-setup.sh
```

---

## Typical Workflow Example

### Scenario: Add a DICOM Modality

```bash
# Step 1: Navigate to repo
cd /opt/projects/orthanc

# Step 2: Edit configuration
nano orthanc.json
# Add your new modality to DicomModalities section

# Step 3: Review changes (optional)
git diff orthanc.json

# Step 4: Commit (optional but recommended)
git add orthanc.json
git commit -m "Added NEW_PACS modality for radiology"

# Step 5: Deploy
./orthanc-manager.sh update

# Output will show:
# ✅ Reading configs from /opt/projects/orthanc
# ✅ Deploying to /opt/orthanc
# ✅ Preserving password and /data path
# ✅ Services restarted

# Step 6: Verify
./orthanc-manager.sh status
curl -u orthanc_admin:helloaide123 http://localhost:8042/modalities

# Step 7: Push to git (optional)
git push
```

---

## Why This Works Perfectly

### ✅ Separation of Concerns
- **Repo (`/opt/projects/orthanc`)**: Source of truth, version controlled
- **Installation (`/opt/orthanc`)**: Running system, managed by scripts
- **Storage (`/data`)**: DICOM files, never touched by updates

### ✅ Clean Workflow
1. Edit in repo
2. Run update from repo
3. Script deploys to installation
4. Data preserved automatically

### ✅ Version Control Friendly
- All your changes in repo
- Can commit before deploying
- Easy to revert: `git revert` + `./orthanc-manager.sh update`

### ✅ Safe Updates
- Scripts read from repo (your templates)
- Scripts write to installation (with real passwords)
- Data at `/data` never touched

---

## Environment Variables (Optional)

If you ever need different paths, you can override:

```bash
# Custom installation location (rare)
ORTHANC_DIR=/custom/path ./orthanc-manager.sh status

# But normally you don't need this - defaults work!
```

---

## Quick Reference

```bash
# Where to work
cd /opt/projects/orthanc

# Install (first time only)
./install-orthanc.sh /data

# Daily operations
./orthanc-manager.sh status    # Check status
./orthanc-manager.sh logs      # View logs

# Make changes
nano orthanc.json              # Edit
./orthanc-manager.sh update    # Deploy

# Maintenance
./orthanc-manager.sh backup    # Backup
./orthanc-manager.sh usage     # Check disk
```

---

## Summary

**YES - The code is already configured exactly as you want!** ✅

- ✅ Scripts read from wherever they're located (your repo)
- ✅ Scripts deploy to `/opt/orthanc` (hardcoded)
- ✅ Storage at `/data` (preserved)
- ✅ All operations from repo directory
- ✅ Clean separation of concerns
- ✅ Version control friendly

**Just run everything from `/opt/projects/orthanc` and you're good!** 🎉

---

## Next Steps

1. **Verify setup:** `cd /opt/projects/orthanc && bash verify-setup.sh`
2. **If not installed yet:** `./install-orthanc.sh /data`
3. **Test an update:** Make a small change and run `./orthanc-manager.sh update`
4. **Use normally:** All commands from repo directory

You're all set! 🚀

