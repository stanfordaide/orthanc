# Migration Guide for Existing Installations

## Quick Check: Do You Need to Migrate?

Run this to check if you need any migration steps:

```bash
# Check if you have the password file
ls -la /opt/orthanc/.db_password

# If you see the file, YOU'RE GOOD! No migration needed.
# If "No such file or directory", follow steps below.
```

---

## Scenario 1: You Have `.db_password` File ✅

**You're already good to go!** Just update the scripts:

```bash
# Copy the updated scripts
cp /dataNAS/people/arogya/projects/orthanc/orthanc-manager.sh /opt/orthanc/
chmod +x /opt/orthanc/orthanc-manager.sh

# Start using the new features immediately
cd /opt/orthanc
./orthanc-manager.sh update
```

**That's it!** No other changes needed.

---

## Scenario 2: Missing `.db_password` File (Rare)

If your installation doesn't have this file (very old installation), create it:

### Step 1: Extract Password from Existing Config

```bash
# Extract password from docker-compose.yml
cd /opt/orthanc
grep "POSTGRES_PASSWORD=" docker-compose.yml | cut -d= -f2 > .db_password.tmp

# Add the proper format
sed -i 's/^/ORTHANC_DB_PASSWORD=/' .db_password.tmp

# Move to final location
mv .db_password.tmp .db_password

# Set proper permissions
chmod 600 .db_password

# Verify it worked
cat .db_password
# Should show: ORTHANC_DB_PASSWORD=<your actual password>
```

### Step 2: Verify Consistency

Make sure all configs have the same password:

```bash
# Check all three locations have same password
PASSWORD_FROM_FILE=$(cat .db_password | cut -d= -f2)
PASSWORD_FROM_COMPOSE=$(grep "POSTGRES_PASSWORD=" docker-compose.yml | cut -d= -f2)
PASSWORD_FROM_JSON=$(grep '"Password"' orthanc.json | sed 's/.*: *"\(.*\)".*/\1/')

echo "Password from .db_password: $PASSWORD_FROM_FILE"
echo "Password from docker-compose: $PASSWORD_FROM_COMPOSE"
echo "Password from orthanc.json: $PASSWORD_FROM_JSON"

# All three should match!
```

### Step 3: Update Scripts

```bash
# Copy the new scripts
cp /dataNAS/people/arogya/projects/orthanc/orthanc-manager.sh /opt/orthanc/
chmod +x /opt/orthanc/orthanc-manager.sh

# Test it works
cd /opt/orthanc
./orthanc-manager.sh validate
```

### Step 4: Test Update Process

```bash
# Make a small test change
cd /dataNAS/people/arogya/projects/orthanc
# Add a comment to orthanc.json
sed -i '2i\    // Updated with new safe update system' orthanc.json

# Apply update
cd /opt/orthanc
./orthanc-manager.sh update

# Verify services still work
./orthanc-manager.sh status
curl http://localhost:8042
```

---

## Scenario 3: Python Not Available

The new update system prefers Python for JSON merging, but works without it:

```bash
# Check if you have Python
python3 --version

# If not installed and you want smart merging:
# Ubuntu/Debian:
sudo apt-get install python3

# RHEL/CentOS:
sudo yum install python3

# If you can't install Python:
# ✅ Updates still work!
# ⚠️  Manual DICOM modalities might not merge (will use new config as-is)
```

---

## Complete Migration Script

If you want to run everything automatically:

```bash
#!/bin/bash
# migration.sh - One-command migration

cd /opt/orthanc

echo "🔍 Checking existing installation..."

# Check if .db_password exists
if [[ -f .db_password ]]; then
    echo "✅ Password file exists - no migration needed!"
else
    echo "⚠️  Creating missing .db_password file..."
    
    # Extract from docker-compose.yml
    if [[ -f docker-compose.yml ]]; then
        grep "POSTGRES_PASSWORD=" docker-compose.yml | cut -d= -f2 | sed 's/^/ORTHANC_DB_PASSWORD=/' > .db_password
        chmod 600 .db_password
        echo "✅ Password file created"
    else
        echo "❌ docker-compose.yml not found!"
        exit 1
    fi
fi

# Update scripts
echo "📝 Updating management scripts..."
cp /dataNAS/people/arogya/projects/orthanc/orthanc-manager.sh ./
chmod +x orthanc-manager.sh
echo "✅ Scripts updated"

# Validate
echo "🔍 Validating installation..."
./orthanc-manager.sh validate

echo "✅ Migration complete! You can now use: ./orthanc-manager.sh update"
```

Save as `/opt/orthanc/migration.sh` and run:

```bash
chmod +x /opt/orthanc/migration.sh
/opt/orthanc/migration.sh
```

---

## Verification Checklist

After migration, verify everything:

- [ ] `.db_password` file exists: `ls -la /opt/orthanc/.db_password`
- [ ] Password is valid: `cat /opt/orthanc/.db_password`
- [ ] Services running: `docker compose ps`
- [ ] Database connected: `docker compose logs orthanc | grep -i database`
- [ ] Web UI accessible: `curl http://localhost:8042`
- [ ] Update works: `./orthanc-manager.sh validate`

---

## Rollback Plan

If something goes wrong during migration:

```bash
# 1. Stop services
cd /opt/orthanc
docker compose stop

# 2. Restore old scripts (if you backed them up)
cp orthanc-manager.sh.backup orthanc-manager.sh

# 3. Or just continue using docker compose directly
docker compose start

# Services will work with old or new scripts!
```

---

## FAQ

### Q: Will this affect my running services?
**A:** No! Migration only creates the `.db_password` file. Services keep running.

### Q: What if I have a custom installation path?
**A:** Replace `/opt/orthanc` with your actual path in all commands.

### Q: Can I test without affecting production?
**A:** Yes! The validation command is safe: `./orthanc-manager.sh validate`

### Q: What if passwords don't match?
**A:** Don't proceed! Your installation may have been manually edited. Contact support or restore from backup.

### Q: Do I need to restart services?
**A:** No, not for creating the password file. Only when running `update`.

### Q: Will old backups still work?
**A:** Yes! Old backups can be restored with the new scripts.

---

## Summary

**Most users:** No migration needed - just copy the new scripts ✅

**Missing .db_password:** Create it from docker-compose.yml (5 minutes)

**No Python:** Still works, just without smart JSON merging

**All scenarios:** Backward compatible, safe, tested ✅

