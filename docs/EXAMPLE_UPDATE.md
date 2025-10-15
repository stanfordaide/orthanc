# Real-World Update Example

## Your Setup
- **Repository:** `/opt/projects/orthanc` (your config templates)
- **Installation:** `/opt/orthanc` (running Orthanc)
- **Storage:** `/data` (DICOM files)

---

## Complete Update Process

### Step 1: Make Changes in Repository

```bash
# Navigate to your repo
cd /opt/projects/orthanc

# Edit the configuration
nano orthanc.json

# Example: Let's add a new DICOM modality
# Find the DicomModalities section and add:
"DicomModalities" : {
    "MERCURE" : [ "orthanc", "172.17.0.1", 11112 ],
    "LPCHROUTER" : [ "LPCHROUTER", "10.50.133.21", 4000 ],
    "NEW_PACS" : [ "NEW_PACS", "192.168.1.50", 104 ]  # <-- NEW!
}

# Save and exit (Ctrl+X, Y, Enter)
```

**Optional:** Commit to version control
```bash
git add orthanc.json
git commit -m "Add NEW_PACS modality"
git push
```

---

### Step 2: Navigate to Installation Directory

```bash
cd /opt/orthanc
```

---

### Step 3: Run the Update Command

```bash
./orthanc-manager.sh update
```

**What you'll see:**

```
🔧 Updating Orthanc configuration...
🔍 Validating update prerequisites...
✅ Database credentials found
✅ DICOM storage accessible
✅ PostgreSQL data accessible
✅ Services are running
✅ Validation passed

Current storage paths:
  • DICOM: /data
  • PostgreSQL: /opt/orthanc/postgres-data

✅ Retrieved existing database credentials

💾 Creating configuration backup...
✅ Configuration backed up to: /opt/orthanc/backups/config_backup_20251015_143022

Stopping services for update...
[+] Running 3/3
 ✔ Container orthanc-ohif      Stopped
 ✔ Container orthanc-orthanc   Stopped  
 ✔ Container orthanc-orthanc-db Stopped

🔧 Checking for volume conflicts...

Preparing updated configuration...
Restoring database credentials...
🔧 Merging configuration (preserving dynamic settings)...
  • Preserved DicomModalities: 4 entries
  • Preserved RegisteredUsers: 1 entries
✅ Configuration merged successfully

Installing updated configuration...
Updating Lua scripts...

Restarting with updated configuration...
[+] Running 4/4
 ✔ Network orthanc_default     Created
 ✔ Container orthanc-orthanc-db Started
 ✔ Container orthanc-orthanc   Started
 ✔ Container orthanc-ohif      Started

✅ Configuration updated successfully
✅ Database credentials preserved
✅ Dynamic settings (modalities, users) preserved

⏳ Waiting for services to initialize...

📊 Orthanc Service Status:
NAME                  IMAGE                      STATUS         PORTS
orthanc-orthanc       jodogne/orthanc-python    Up 12 seconds  0.0.0.0:4242->4242/tcp, 0.0.0.0:8042->8042/tcp
orthanc-orthanc-db    postgres:15               Up 14 seconds  0.0.0.0:5433->5432/tcp
orthanc-ohif          mercureimaging/ohif       Up 11 seconds  0.0.0.0:8008->80/tcp

🌐 Service URLs:
  • Orthanc Web UI: http://localhost:8042
  • OHIF Viewer: http://localhost:8008
  • DICOM Port: 4242
  • PostgreSQL: localhost:5433

📁 Storage Locations:
  • DICOM Storage: /data
  • Database: /opt/orthanc/postgres-data

🔗 Connectivity Tests:
  • Orthanc: ✅ Online
  • OHIF: ✅ Online
```

---

### Step 4: Verify the Update

```bash
# Check services are running
./orthanc-manager.sh status

# Check logs for any issues
./orthanc-manager.sh logs
# Press Ctrl+C to exit logs

# Test web UI
curl http://localhost:8042

# Optional: Check the new modality is available
curl -u orthanc_admin:helloaide123 http://localhost:8042/modalities
```

**Expected response:**
```json
[
  "MERCURE",
  "LPCHROUTER", 
  "LPCHTROUTER",
  "MODLINK",
  "NEW_PACS"    # <-- Your new modality!
]
```

---

## What Happens Behind the Scenes

### Files Involved

**In `/opt/projects/orthanc` (your repo):**
```
orthanc.json           # Has ChangePasswordHere (template)
docker-compose.yml     # Has default paths (template)
lua-scripts/           # Your automation scripts
```

**In `/opt/orthanc` (running installation):**
```
orthanc.json           # Has REAL password (secure)
docker-compose.yml     # Has /data path (your actual setup)
.db_password           # Contains actual DB password
postgres-data/         # PostgreSQL database
backups/               # Automatic backups
```

**In `/data` (your storage):**
```
# All your DICOM files
# This location is PRESERVED during update
```

---

### The Update Process Flow

```
1. VALIDATION
   ├─ Check .db_password exists ✓
   ├─ Check /data accessible ✓
   ├─ Check /opt/orthanc/postgres-data exists ✓
   └─ Check services running ✓

2. BACKUP
   ├─ Create /opt/orthanc/backups/config_backup_TIMESTAMP/
   ├─ Copy current orthanc.json (with real password)
   ├─ Copy current docker-compose.yml (with /data path)
   └─ Copy .db_password

3. PASSWORD EXTRACTION
   └─ Read password from /opt/orthanc/.db_password
      Result: DB_PWD="xYz123AbC456..." (your actual password)

4. STAGING (in temporary directory)
   ├─ Copy /opt/projects/orthanc/orthanc.json → /tmp/tmpXXX/
   ├─ Copy /opt/projects/orthanc/docker-compose.yml → /tmp/tmpXXX/
   ├─ Replace "ChangePasswordHere" with "xYz123AbC456..."
   └─ Replace "/opt/orthanc/orthanc-storage" with "/data"

5. CONFIGURATION MERGE
   ├─ Load OLD: /opt/orthanc/orthanc.json
   ├─ Load NEW: /tmp/tmpXXX/orthanc.json
   ├─ Extract from OLD: DicomModalities (MERCURE, LPCHROUTER, etc.)
   ├─ Extract from OLD: RegisteredUsers (your custom users)
   ├─ Merge into NEW config
   └─ Result: NEW has your NEW_PACS + OLD modalities preserved!

6. DEPLOYMENT
   ├─ Copy merged configs to /opt/orthanc/
   ├─ Update lua-scripts/
   └─ Clean up /tmp/tmpXXX/

7. RESTART
   ├─ docker compose down
   ├─ docker compose up -d
   └─ Wait for services to initialize

8. VERIFICATION
   └─ Test connectivity to Orthanc
```

---

## Common Scenarios

### Scenario A: Add Performance Tuning

**1. Edit in repo:**
```bash
cd /opt/projects/orthanc
nano orthanc.json

# Change these values:
"ConcurrentJobs" : 4,          # Was: 2
"HttpThreadsCount" : 100,      # Was: 50
"MaximumStorageSize" : 500000, # Was: 0
```

**2. Apply:**
```bash
cd /opt/orthanc
./orthanc-manager.sh update
```

**Result:** 
- ✅ Performance settings updated
- ✅ Your DICOM modalities preserved
- ✅ Database password maintained
- ✅ /data path unchanged

---

### Scenario B: Update Lua Script

**1. Edit script:**
```bash
cd /opt/projects/orthanc/lua-scripts
nano autosend_leg_length.lua
# Make your changes
```

**2. Apply:**
```bash
cd /opt/orthanc
./orthanc-manager.sh update
```

**Result:**
- ✅ New Lua script deployed
- ✅ All other settings preserved

---

### Scenario C: Change DICOM Server Settings

**1. Edit in repo:**
```bash
cd /opt/projects/orthanc
nano orthanc.json

# Modify DICOM settings:
"DicomAet" : "ORTHANC_NEW",        # Changed from ORTHANC_LPCH
"DicomAlwaysAllowStore" : false,   # Changed from true (more secure)
```

**2. Apply:**
```bash
cd /opt/orthanc
./orthanc-manager.sh update
```

**Result:**
- ✅ DICOM settings updated
- ✅ New AET title active
- ✅ All data intact at /data

---

## Verification Checklist

After any update, verify:

```bash
cd /opt/orthanc

# 1. Services running
./orthanc-manager.sh status

# 2. Database connected
docker compose logs orthanc | grep "PostgreSQL database is accessible"

# 3. DICOM storage accessible
ls /data/
# Should show your DICOM files

# 4. Web UI accessible
curl -I http://localhost:8042
# Should return HTTP 200 or 302

# 5. Configuration applied
# Check specific setting you changed:
docker compose exec orthanc cat /run/secrets/orthanc.json | grep "ConcurrentJobs"
```

---

## If Something Goes Wrong

### Rollback Process

```bash
cd /opt/orthanc

# 1. Check what backups exist
ls -la backups/

# 2. Restore from most recent backup
./orthanc-manager.sh restore

# Select the backup created before update
# (It will be the newest one with timestamp)

# 3. Services will restart with old configuration
```

### Check Logs

```bash
# View all service logs
docker compose logs

# View just Orthanc logs
docker compose logs orthanc

# Follow logs in real-time
docker compose logs -f orthanc
```

---

## Best Practices

### Before Update
```bash
# 1. Check current status
cd /opt/orthanc
./orthanc-manager.sh status

# 2. Create manual backup (optional, update does this automatically)
./orthanc-manager.sh backup

# 3. Note current disk usage
./orthanc-manager.sh usage
```

### After Update
```bash
# 1. Verify services
./orthanc-manager.sh status

# 2. Test connectivity
curl http://localhost:8042

# 3. Check logs for errors
docker compose logs orthanc | grep -i error

# 4. Verify data intact
ls /data/ | wc -l  # Count should be same as before
```

---

## Time Expectations

| Operation | Duration |
|-----------|----------|
| Edit orthanc.json | 2-5 minutes |
| Run update command | 30-60 seconds |
| Service restart | 20-30 seconds |
| Verification | 1-2 minutes |
| **Total downtime** | **20-30 seconds** |

---

## Summary: Your Update Process

```bash
# IN REPO: Make changes
cd /opt/projects/orthanc
nano orthanc.json
# ... make your changes ...

# IN INSTALLATION: Apply updates
cd /opt/orthanc
./orthanc-manager.sh update
# ✅ Done! Services running with new config

# VERIFY
./orthanc-manager.sh status
curl http://localhost:8042
```

**That's it! Your data at `/data` is never touched, passwords are preserved, and your customizations are kept!** 🎉

