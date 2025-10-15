#!/bin/bash

# orthanc_manager.sh - Orthanc Management Script
# Usage: ./orthanc_manager.sh [command]
# Commands: start, stop, restart, update, status, logs, delete, purge, backup, restore

set -e  # Exit on any error

# Configuration
ORTHANC_DIR="/opt/orthanc"
BACKUP_DIR="/opt/orthanc/backups"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to detect DICOM storage path from docker-compose.yml
detect_dicom_storage_path() {
    local dicom_storage_path=""
    
    if [[ -f "$ORTHANC_DIR/docker-compose.yml" ]]; then
        # Extract the device path for orthanc-storage volume
        dicom_storage_path=$(grep -A 5 "orthanc-storage:" "$ORTHANC_DIR/docker-compose.yml" | grep "device:" | sed "s/.*device: *['\"]*//" | sed "s/['\"]*.*//" | head -1)
    fi
    
    # Fallback to default if not found
    if [[ -z "$dicom_storage_path" ]]; then
        dicom_storage_path="/opt/orthanc/orthanc-storage"
    fi
    
    echo "$dicom_storage_path"
}

# Function to detect PostgreSQL data path from docker-compose.yml
detect_postgres_data_path() {
    local postgres_data_path=""
    
    if [[ -f "$ORTHANC_DIR/docker-compose.yml" ]]; then
        # Extract the device path for postgres data volume
        postgres_data_path=$(grep -A 5 "orthanc-db-data:" "$ORTHANC_DIR/docker-compose.yml" | grep "device:" | sed "s/.*device: *['\"]*//" | sed "s/['\"]*.*//" | head -1)
    fi
    
    # Fallback to default if not found
    if [[ -z "$postgres_data_path" ]]; then
        postgres_data_path="/opt/orthanc/postgres-data"
    fi
    
    echo "$postgres_data_path"
}

# Function to print usage
show_usage() {
    echo -e "${CYAN}🏥 Orthanc Management Script${NC}"
    echo -e "${YELLOW}Usage: \\$0 [command]${NC}"
    echo -e ""
    echo -e "${BLUE}Available commands:${NC}"
    echo -e "  ${GREEN}start${NC}     - Start Orthanc services"
    echo -e "  ${GREEN}stop${NC}      - Stop Orthanc services"
    echo -e "  ${GREEN}restart${NC}   - Restart Orthanc services"
    echo -e "  ${GREEN}status${NC}    - Show service status"
    echo -e "  ${GREEN}logs${NC}      - Show service logs (follow mode)"
    echo -e "  ${GREEN}update${NC}    - Update Orthanc configuration and restart"
    echo -e "  ${GREEN}backup${NC}    - Backup Orthanc data and configuration"
    echo -e "  ${GREEN}restore${NC}   - Restore from backup"
    echo -e "  ${GREEN}usage${NC}     - Show disk usage and storage paths"
    echo -e "  ${GREEN}clean${NC}     - Clean old backups"
    echo -e "  ${YELLOW}delete${NC}    - Stop and remove containers (keep data)"
    echo -e "  ${RED}purge${NC}     - Complete removal (containers + data + config)"
    echo -e ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  \\$0 start"
    echo -e "  \\$0 logs"
    echo -e "  \\$0 backup"
    echo -e "  \\$0 update"
}

# Function to check if Orthanc is installed
check_installation() {
    if [[ ! -d "$ORTHANC_DIR" ]]; then
        echo -e "${RED}❌ Orthanc installation not found at $ORTHANC_DIR${NC}"
        echo -e "${YELLOW}Please run install_orthanc.sh first${NC}"
        exit 1
    fi
    
    if [[ ! -f "$ORTHANC_DIR/docker-compose.yml" ]]; then
        echo -e "${RED}❌ docker-compose.yml not found in $ORTHANC_DIR${NC}"
        exit 1
    fi
}

# Function to start services
start_services() {
    echo -e "${GREEN}🚀 Starting Orthanc services...${NC}"
    cd "$ORTHANC_DIR"
    docker compose up -d
    echo -e "${GREEN}✅ Services started${NC}"
    
    echo -e "${YELLOW}⏳ Waiting for services to initialize...${NC}"
    sleep 10
    show_status
}

# Function to stop services
stop_services() {
    echo -e "${YELLOW}🛑 Stopping Orthanc services...${NC}"
    cd "$ORTHANC_DIR"
    docker compose stop
    echo -e "${GREEN}✅ Services stopped${NC}"
}

# Function to restart services
restart_services() {
    echo -e "${YELLOW}🔄 Restarting Orthanc services...${NC}"
    cd "$ORTHANC_DIR"
    docker compose restart
    echo -e "${GREEN}✅ Services restarted${NC}"
    
    echo -e "${YELLOW}⏳ Waiting for services to initialize...${NC}"
    sleep 10
    show_status
}

# Function to show status
show_status() {
    echo -e "${BLUE}📊 Orthanc Service Status:${NC}"
    cd "$ORTHANC_DIR"
    docker compose ps
    
    echo -e "\n${BLUE}🌐 Service URLs:${NC}"
    echo -e "  • Orthanc Web UI: http://localhost:8042"
    echo -e "  • OHIF Viewer: http://localhost:8008"
    echo -e "  • DICOM Port: 4242"
    echo -e "  • PostgreSQL: localhost:5433"
    
    # Show storage paths
    local dicom_path=$(detect_dicom_storage_path)
    local postgres_path=$(detect_postgres_data_path)
    
    echo -e "\n${BLUE}📁 Storage Locations:${NC}"
    echo -e "  • DICOM Storage: $dicom_path"
    echo -e "  • Database: $postgres_path"
    
    # Test connectivity
    echo -e "\n${BLUE}🔗 Connectivity Tests:${NC}"
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8042 | grep -q "200\|302\|401"; then
        echo -e "  • Orthanc: ${GREEN}✅ Online${NC}"
    else
        echo -e "  • Orthanc: ${RED}❌ Offline${NC}"
    fi
    
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8008 | grep -q "200\|302"; then
        echo -e "  • OHIF: ${GREEN}✅ Online${NC}"
    else
        echo -e "  • OHIF: ${RED}❌ Offline${NC}"
    fi
}

# Function to show logs
show_logs() {
    echo -e "${BLUE}📋 Orthanc Service Logs (Press Ctrl+C to exit):${NC}"
    cd "$ORTHANC_DIR"
    docker compose logs -f
}

# Function to handle volume conflicts during update
fix_volume_conflicts() {
    echo -e "${YELLOW}🔧 Checking for volume conflicts...${NC}"
    
    local volumes_to_remove=()
    
    # Check if volumes exist with different configurations
    if docker volume ls -q | grep -q "orthanc_orthanc-storage"; then
        volumes_to_remove+=("orthanc_orthanc-storage")
    fi
    
    if docker volume ls -q | grep -q "orthanc_orthanc-db-data"; then
        volumes_to_remove+=("orthanc_orthanc-db-data")
    fi
    
    if [[ ${#volumes_to_remove[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  Found conflicting Docker volumes that need to be recreated:${NC}"
        printf '   • %s\n' "${volumes_to_remove[@]}"
        echo -e "${YELLOW}This will recreate the volumes with new paths but preserve your data${NC}"
        echo -e "${YELLOW}Continue? (yes/no): ${NC}"
        read -r confirm
        
        if [[ "$confirm" == "yes" ]]; then
            echo -e "${YELLOW}Removing old volumes...${NC}"
            for volume in "${volumes_to_remove[@]}"; do
                echo -e "  Removing: $volume"
                docker volume rm "$volume" 2>/dev/null || true
            done
            echo -e "${GREEN}✅ Volume conflicts resolved${NC}"
        else
            echo -e "${RED}❌ Update cancelled${NC}"
            exit 1
        fi
    fi
}

# Function to merge JSON configurations (preserves dynamic settings)
merge_json_config() {
    local old_config="$1"
    local new_config="$2"
    local output_config="$3"
    
    # Fields to preserve from old config
    local preserve_fields=("DicomModalities" "RegisteredUsers" "OrthancPeers")
    
    echo -e "${BLUE}Merging configuration (preserving dynamic settings)...${NC}"
    
    # Use Python to merge JSON if available, otherwise just use new config
    if command -v python3 &> /dev/null; then
        python3 << EOF
import json
import sys

try:
    with open('$old_config', 'r') as f:
        old = json.load(f)
    with open('$new_config', 'r') as f:
        new = json.load(f)
    
    # Preserve specific fields from old config
    preserve = ['DicomModalities', 'RegisteredUsers', 'OrthancPeers']
    for field in preserve:
        if field in old and old[field]:
            # Only preserve if there's actual content
            if isinstance(old[field], dict) and len(old[field]) > 0:
                new[field] = old[field]
                print(f"  • Preserved {field}: {len(old[field])} entries", file=sys.stderr)
            elif isinstance(old[field], list) and len(old[field]) > 0:
                new[field] = old[field]
                print(f"  • Preserved {field}: {len(old[field])} entries", file=sys.stderr)
    
    with open('$output_config', 'w') as f:
        json.dump(new, f, indent=2)
    
    print("✅ Configuration merged successfully", file=sys.stderr)
except Exception as e:
    print(f"⚠️  Could not merge JSON: {e}", file=sys.stderr)
    # Fallback: just copy new config
    import shutil
    shutil.copy('$new_config', '$output_config')
EOF
    else
        echo -e "${YELLOW}  • Python not available, using new config as-is${NC}"
        cp "$new_config" "$output_config"
    fi
}

# Function to validate update prerequisites
validate_update() {
    echo -e "${YELLOW}🔍 Validating update prerequisites...${NC}"
    
    local validation_failed=0
    
    # Check if database password file exists
    if [[ ! -f "$ORTHANC_DIR/.db_password" ]]; then
        echo -e "${RED}❌ Database password file not found${NC}"
        validation_failed=1
    else
        echo -e "${GREEN}✅ Database credentials found${NC}"
    fi
    
    # Check if data directories are accessible
    local dicom_path=$(detect_dicom_storage_path)
    local postgres_path=$(detect_postgres_data_path)
    
    if [[ ! -d "$dicom_path" ]]; then
        echo -e "${YELLOW}⚠️  DICOM storage not found: $dicom_path${NC}"
    elif [[ ! -w "$dicom_path" ]]; then
        echo -e "${YELLOW}⚠️  DICOM storage not writable: $dicom_path${NC}"
    else
        echo -e "${GREEN}✅ DICOM storage accessible${NC}"
    fi
    
    if [[ ! -d "$postgres_path" ]]; then
        echo -e "${YELLOW}⚠️  PostgreSQL data not found: $postgres_path${NC}"
    else
        echo -e "${GREEN}✅ PostgreSQL data accessible${NC}"
    fi
    
    # Check if containers are running
    cd "$ORTHANC_DIR"
    if docker compose ps | grep -q "Up"; then
        echo -e "${GREEN}✅ Services are running${NC}"
    else
        echo -e "${YELLOW}⚠️  Services are not running (will start after update)${NC}"
    fi
    
    if [[ $validation_failed -eq 1 ]]; then
        echo -e "${RED}❌ Validation failed - please fix issues before updating${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Validation passed${NC}"
}

# Function to update configuration
update_config() {
    echo -e "${YELLOW}🔧 Updating Orthanc configuration...${NC}"
    
    # Check if source files exist
    local source_files=("docker-compose.yml" "orthanc.json" "nginx.conf")
    local missing_files=()
    
    for file in "${source_files[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo -e "${RED}❌ Missing source files in $SCRIPT_DIR:${NC}"
        printf '   • %s\n' "${missing_files[@]}"
        echo -e "${YELLOW}Make sure you're running this from the directory with updated config files${NC}"
        exit 1
    fi
    
    # Validate prerequisites
    validate_update
    
    # Detect current storage paths before backup
    local current_dicom_path=$(detect_dicom_storage_path)
    local current_postgres_path=$(detect_postgres_data_path)
    
    echo -e "${BLUE}Current storage paths:${NC}"
    echo -e "  • DICOM: $current_dicom_path"
    echo -e "  • PostgreSQL: $current_postgres_path"
    
    # Get the database password BEFORE any changes
    local DB_PWD=""
    if [[ -f "$ORTHANC_DIR/.db_password" ]]; then
        DB_PWD=$(grep "ORTHANC_DB_PASSWORD=" "$ORTHANC_DIR/.db_password" | cut -d= -f2)
        echo -e "${GREEN}✅ Retrieved existing database credentials${NC}"
    else
        echo -e "${RED}❌ Cannot find database password file!${NC}"
        echo -e "${YELLOW}Update aborted to prevent breaking database connection${NC}"
        exit 1
    fi
    
    # Backup current config
    backup_config
    
    # Stop services
    echo -e "${YELLOW}Stopping services for update...${NC}"
    cd "$ORTHANC_DIR"
    docker compose stop
    docker compose down

    # Check and fix volume conflicts
    fix_volume_conflicts
    
    # Copy new configuration files to temp location first
    echo -e "${YELLOW}Preparing updated configuration...${NC}"
    local temp_dir=$(mktemp -d)
    cp "$SCRIPT_DIR/docker-compose.yml" "$temp_dir/"
    cp "$SCRIPT_DIR/orthanc.json" "$temp_dir/"
    cp "$SCRIPT_DIR/nginx.conf" "$temp_dir/"
    
    # Update passwords in temp files
    echo -e "${YELLOW}Restoring database credentials...${NC}"
    sed -i "s/ChangePasswordHere/$DB_PWD/g" "$temp_dir/orthanc.json"
    sed -i "s/POSTGRES_PASSWORD=ChangePasswordHere/POSTGRES_PASSWORD=$DB_PWD/g" "$temp_dir/docker-compose.yml"
    
    # Update storage paths in docker-compose.yml to maintain current paths
    sed -i "s|device: '/opt/orthanc/orthanc-storage'|device: '$current_dicom_path'|g" "$temp_dir/docker-compose.yml"
    sed -i "s|device: '/opt/orthanc/postgres-data'|device: '$current_postgres_path'|g" "$temp_dir/docker-compose.yml"
    
    # Merge orthanc.json configurations (preserve dynamic settings)
    if [[ -f "$ORTHANC_DIR/orthanc.json" ]]; then
        merge_json_config "$ORTHANC_DIR/orthanc.json" "$temp_dir/orthanc.json" "$temp_dir/orthanc.json.merged"
        mv "$temp_dir/orthanc.json.merged" "$temp_dir/orthanc.json"
    fi
    
    # Now copy the prepared configs to the actual location
    echo -e "${YELLOW}Installing updated configuration...${NC}"
    cp "$temp_dir/docker-compose.yml" "$ORTHANC_DIR/"
    cp "$temp_dir/orthanc.json" "$ORTHANC_DIR/"
    cp "$temp_dir/nginx.conf" "$ORTHANC_DIR/"
    
    # Clean up temp directory
    rm -rf "$temp_dir"
    
    # Update lua scripts
    if [[ -d "$SCRIPT_DIR/lua-scripts" ]]; then
        echo -e "${YELLOW}Updating Lua scripts...${NC}"
        cp -r "$SCRIPT_DIR/lua-scripts"/* "$ORTHANC_DIR/lua-scripts/" 2>/dev/null || true
    fi
    
    # Check if storage paths changed (they shouldn't with our new logic)
    local new_dicom_path=$(detect_dicom_storage_path)
    local new_postgres_path=$(detect_postgres_data_path)
    
    if [[ "$current_dicom_path" != "$new_dicom_path" ]]; then
        echo -e "${YELLOW}⚠️  DICOM storage path changed: $current_dicom_path → $new_dicom_path${NC}"
        echo -e "${YELLOW}This should not happen during normal updates${NC}"
    fi
    
    if [[ "$current_postgres_path" != "$new_postgres_path" ]]; then
        echo -e "${YELLOW}⚠️  PostgreSQL data path changed: $current_postgres_path → $new_postgres_path${NC}"
        echo -e "${YELLOW}This should not happen during normal updates${NC}"
    fi
    
    # Restart services
    echo -e "${YELLOW}Restarting with updated configuration...${NC}"
    docker compose up -d
    
    echo -e "${GREEN}✅ Configuration updated successfully${NC}"
    echo -e "${GREEN}✅ Database credentials preserved${NC}"
    echo -e "${GREEN}✅ Dynamic settings (modalities, users) preserved${NC}"
    
    echo -e "${YELLOW}⏳ Waiting for services to initialize...${NC}"
    sleep 10
    show_status
}

# Function to backup configuration
backup_config() {
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_path="$BACKUP_DIR/config_backup_$timestamp"
    
    echo -e "${YELLOW}💾 Creating configuration backup...${NC}"
    
    mkdir -p "$backup_path"
    
    # Backup configuration files
    cp "$ORTHANC_DIR/docker-compose.yml" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/orthanc.json" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/nginx.conf" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/.db_password" "$backup_path/" 2>/dev/null || true
    cp -r "$ORTHANC_DIR/lua-scripts" "$backup_path/" 2>/dev/null || true
    
    echo -e "${GREEN}✅ Configuration backed up to: $backup_path${NC}"
}

# Function to create database dump
backup_database_dump() {
    local backup_path="$1"
    
    echo -e "${YELLOW}Creating database dump for faster restore...${NC}"
    
    cd "$ORTHANC_DIR"
    
    # Get database password
    local DB_PWD=""
    if [[ -f "$ORTHANC_DIR/.db_password" ]]; then
        DB_PWD=$(grep "ORTHANC_DB_PASSWORD=" "$ORTHANC_DIR/.db_password" | cut -d= -f2)
    fi
    
    if [[ -z "$DB_PWD" ]]; then
        echo -e "${YELLOW}⚠️  Could not retrieve database password, skipping database dump${NC}"
        return
    fi
    
    # Create database dump using pg_dump from the postgres container
    if docker compose ps orthanc-db | grep -q "Up"; then
        echo -e "${BLUE}  • Dumping PostgreSQL database...${NC}"
        docker compose exec -T orthanc-db pg_dump -U orthanc -d orthanc > "$backup_path/database_dump.sql" 2>/dev/null || {
            echo -e "${YELLOW}⚠️  Database dump failed (container might be stopped)${NC}"
        }
        
        if [[ -f "$backup_path/database_dump.sql" ]] && [[ -s "$backup_path/database_dump.sql" ]]; then
            gzip "$backup_path/database_dump.sql"
            echo -e "${GREEN}  • Database dump created: database_dump.sql.gz${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  Database container not running, skipping database dump${NC}"
    fi
}

# Function to create full backup
create_backup() {
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_path="$BACKUP_DIR/full_backup_$timestamp"
    
    echo -e "${YELLOW}💾 Creating full backup (data + config + database)...${NC}"
    
    # Detect current storage paths
    local dicom_path=$(detect_dicom_storage_path)
    local postgres_path=$(detect_postgres_data_path)
    
    echo -e "${BLUE}Backing up from:${NC}"
    echo -e "  • DICOM Storage: $dicom_path"
    echo -e "  • PostgreSQL Data: $postgres_path"
    
    mkdir -p "$backup_path"
    
    # Backup database dump BEFORE stopping services
    backup_database_dump "$backup_path"
    
    # Stop services for consistent backup
    echo -e "${YELLOW}Stopping services for backup...${NC}"
    cd "$ORTHANC_DIR"
    docker compose stop
    
    # Backup configuration
    echo -e "${YELLOW}Backing up configuration files...${NC}"
    cp "$ORTHANC_DIR/docker-compose.yml" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/orthanc.json" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/nginx.conf" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/.db_password" "$backup_path/" 2>/dev/null || true
    cp -r "$ORTHANC_DIR/lua-scripts" "$backup_path/" 2>/dev/null || true
    
# Backup data directories using detected paths
    echo -e "${YELLOW}Backing up DICOM storage from $dicom_path...${NC}"
    if [[ -d "$dicom_path" ]]; then
        cp -r "$dicom_path" "$backup_path/dicom-storage" 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠️  DICOM storage directory not found: $dicom_path${NC}"
    fi
    
    echo -e "${YELLOW}Backing up PostgreSQL data from $postgres_path...${NC}"
    if [[ -d "$postgres_path" ]]; then
        cp -r "$postgres_path" "$backup_path/postgres-data" 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠️  PostgreSQL data directory not found: $postgres_path${NC}"
    fi
    
    # Create backup info file with storage paths
    cat > "$backup_path/backup_info.txt" << EOF
Backup Created: $(date)
Orthanc Version: $(docker image ls jodogne/orthanc-python --format "table {{.Tag}}" | tail -n +2 | head -1)
PostgreSQL Version: $(docker image ls postgres --format "table {{.Tag}}" | tail -n +2 | head -1)
Backup Type: Full (Configuration + Data + Database Dump)
DICOM Storage Path: $dicom_path
PostgreSQL Data Path: $postgres_path
Database Dump: $([ -f "$backup_path/database_dump.sql.gz" ] && echo "Yes" || echo "No")
EOF
    
    # Restart services
    echo -e "${YELLOW}Restarting services...${NC}"
    docker compose start
    
    echo -e "${GREEN}✅ Full backup created: $backup_path${NC}"
    echo -e "${YELLOW}Backup size: $(du -sh "$backup_path" | cut -f1)${NC}"
    
    if [[ -f "$backup_path/database_dump.sql.gz" ]]; then
        echo -e "${GREEN}✅ Database dump included for faster restore${NC}"
    fi
}

# Function to restore from backup
restore_backup() {
    echo -e "${YELLOW}📋 Available backups:${NC}"
    
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        echo -e "${RED}❌ No backups found${NC}"
        exit 1
    fi
    
    local backups=($(ls -t "$BACKUP_DIR"/))
    local i=1
    
    for backup in "${backups[@]}"; do
        local backup_path="$BACKUP_DIR/$backup"
        if [[ -d "$backup_path" ]]; then
            echo -e "  ${i}. $backup"
            if [[ -f "$backup_path/backup_info.txt" ]]; then
                echo -e "     $(head -1 "$backup_path/backup_info.txt" | cut -d: -f2-)"
                # Show storage paths if available
                local dicom_backup_path=$(grep "DICOM Storage Path:" "$backup_path/backup_info.txt" 2>/dev/null | cut -d: -f2- | xargs)
                local postgres_backup_path=$(grep "PostgreSQL Data Path:" "$backup_path/backup_info.txt" 2>/dev/null | cut -d: -f2- | xargs)
                if [[ -n "$dicom_backup_path" ]]; then
                    echo -e "     DICOM: $dicom_backup_path"
                fi
                if [[ -n "$postgres_backup_path" ]]; then
                    echo -e "     DB: $postgres_backup_path"
                fi
            fi
            ((i++))
        fi
    done
    
    echo -e "${YELLOW}Enter backup number to restore (or 0 to cancel): ${NC}"
    read -r choice
    
    if [[ "$choice" == "0" ]]; then
        echo -e "${YELLOW}Restore cancelled${NC}"
        return
    fi
    
    if [[ "$choice" -gt 0 ]] && [[ "$choice" -lt "$i" ]]; then
        local selected_backup="${backups[$((choice-1))]}"
        local backup_path="$BACKUP_DIR/$selected_backup"
        
        echo -e "${RED}⚠️  WARNING: This will overwrite current Orthanc installation!${NC}"
        echo -e "${YELLOW}Are you sure you want to restore from $selected_backup? (yes/no): ${NC}"
        read -r confirm
        
        if [[ "$confirm" == "yes" ]]; then
            restore_from_path "$backup_path"
        else
            echo -e "${YELLOW}Restore cancelled${NC}"
        fi
    else
        echo -e "${RED}❌ Invalid selection${NC}"
    fi
}

# Function to restore database from dump
restore_database_dump() {
    local backup_path="$1"
    
    if [[ ! -f "$backup_path/database_dump.sql.gz" ]]; then
        echo -e "${YELLOW}⚠️  No database dump found in backup, using data directory restore${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}📊 Restoring database from SQL dump...${NC}"
    
    cd "$ORTHANC_DIR"
    
    # Wait for database to be ready
    echo -e "${BLUE}  • Waiting for PostgreSQL to be ready...${NC}"
    sleep 5
    
    # Drop and recreate database
    echo -e "${BLUE}  • Recreating database...${NC}"
    docker compose exec -T orthanc-db psql -U orthanc -d postgres -c "DROP DATABASE IF EXISTS orthanc;" 2>/dev/null || true
    docker compose exec -T orthanc-db psql -U orthanc -d postgres -c "CREATE DATABASE orthanc;" 2>/dev/null || true
    
    # Restore from dump
    echo -e "${BLUE}  • Importing database dump...${NC}"
    gunzip -c "$backup_path/database_dump.sql.gz" | docker compose exec -T orthanc-db psql -U orthanc -d orthanc 2>/dev/null || {
        echo -e "${RED}❌ Database restore failed${NC}"
        return 1
    }
    
    echo -e "${GREEN}✅ Database restored from SQL dump${NC}"
    return 0
}

# Function to restore from specific path
restore_from_path() {
    local backup_path="$1"
    
    echo -e "${YELLOW}🔄 Restoring from backup: $(basename "$backup_path")${NC}"
    
    # Get current storage paths
    local current_dicom_path=$(detect_dicom_storage_path)
    local current_postgres_path=$(detect_postgres_data_path)
    
    echo -e "${BLUE}Restoring to current paths:${NC}"
    echo -e "  • DICOM: $current_dicom_path"
    echo -e "  • PostgreSQL: $current_postgres_path"
    
    # Check if we have a database dump
    local use_db_dump=false
    if [[ -f "$backup_path/database_dump.sql.gz" ]]; then
        echo -e "${GREEN}✅ Database dump found in backup${NC}"
        echo -e "${YELLOW}Use SQL dump for faster restore? (yes/no): ${NC}"
        read -r use_dump_choice
        if [[ "$use_dump_choice" == "yes" ]]; then
            use_db_dump=true
        fi
    fi
    
    # Stop services
    cd "$ORTHANC_DIR"
    docker compose down
    
    # Restore configuration files
    echo -e "${YELLOW}Restoring configuration...${NC}"
    cp "$backup_path/docker-compose.yml" "$ORTHANC_DIR/" 2>/dev/null || true
    cp "$backup_path/orthanc.json" "$ORTHANC_DIR/" 2>/dev/null || true
    cp "$backup_path/nginx.conf" "$ORTHANC_DIR/" 2>/dev/null || true
    cp "$backup_path/.db_password" "$ORTHANC_DIR/" 2>/dev/null || true
    
    if [[ -d "$backup_path/lua-scripts" ]]; then
        rm -rf "$ORTHANC_DIR/lua-scripts"
        cp -r "$backup_path/lua-scripts" "$ORTHANC_DIR/"
    fi
    
    # Restore DICOM storage
    if [[ -d "$backup_path/dicom-storage" ]]; then
        echo -e "${YELLOW}Restoring DICOM storage to $current_dicom_path...${NC}"
        rm -rf "$current_dicom_path"
        mkdir -p "$(dirname "$current_dicom_path")"
        cp -r "$backup_path/dicom-storage" "$current_dicom_path"
        
        # Set appropriate permissions
        if [[ $EUID -eq 0 ]]; then
            chown -R 1000:1000 "$current_dicom_path"
        else
            chown -R $USER:$USER "$current_dicom_path" 2>/dev/null || true
        fi
    fi
    
    # Handle database restore based on choice
    if [[ "$use_db_dump" == true ]]; then
        # Clear PostgreSQL data directory and start fresh
        echo -e "${YELLOW}Clearing PostgreSQL data directory for fresh restore...${NC}"
        rm -rf "$current_postgres_path"
        mkdir -p "$current_postgres_path"
        
        # Set PostgreSQL permissions
        if [[ $EUID -eq 0 ]]; then
            chown -R 999:999 "$current_postgres_path"
        else
            chown -R 999:999 "$current_postgres_path" 2>/dev/null || true
        fi
        
        # Start database container first
        echo -e "${YELLOW}Starting PostgreSQL container...${NC}"
        docker compose up -d orthanc-db
        sleep 10
        
        # Restore from SQL dump
        restore_database_dump "$backup_path"
        
        # Now start Orthanc
        echo -e "${YELLOW}Starting Orthanc services...${NC}"
        docker compose up -d
    else
        # Traditional restore - copy postgres data directory
        if [[ -d "$backup_path/postgres-data" ]]; then
            echo -e "${YELLOW}Restoring PostgreSQL data to $current_postgres_path...${NC}"
            rm -rf "$current_postgres_path"
            mkdir -p "$(dirname "$current_postgres_path")"
            cp -r "$backup_path/postgres-data" "$current_postgres_path"
            
            # Set PostgreSQL permissions
            if [[ $EUID -eq 0 ]]; then
                chown -R 999:999 "$current_postgres_path"
            else
                chown -R 999:999 "$current_postgres_path" 2>/dev/null || true
            fi
        fi
        
        # Start all services
        echo -e "${YELLOW}Starting restored services...${NC}"
        docker compose up -d
    fi
    
    echo -e "${GREEN}✅ Restore completed${NC}"
    
    sleep 10
    show_status
}

# Function to delete (remove containers, keep data)
delete_installation() {
    local dicom_path=$(detect_dicom_storage_path)
    local postgres_path=$(detect_postgres_data_path)
    
    echo -e "${YELLOW}⚠️  This will stop and remove Orthanc containers but keep data${NC}"
    echo -e "${BLUE}Data will be preserved in:${NC}"
    echo -e "  • DICOM Storage: $dicom_path"
    echo -e "  • PostgreSQL Data: $postgres_path"
    echo -e "${YELLOW}Are you sure? (yes/no): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}Delete cancelled${NC}"
        return
    fi
    
    echo -e "${YELLOW}🗑️  Removing Orthanc containers...${NC}"
    
    cd "$ORTHANC_DIR"
    
    # Stop and remove containers
    docker compose down
    
    # Remove any orphaned containers
    docker compose down --remove-orphans
    
    # Remove images (optional - comment out if you want to keep images)
    echo -e "${YELLOW}Removing Docker images...${NC}"
    docker compose down --rmi all 2>/dev/null || true
    
    echo -e "${GREEN}✅ Containers removed${NC}"
    echo -e "${YELLOW}📁 Data preserved in:${NC}"
    echo -e "  • $dicom_path (DICOM files)"
    echo -e "  • $postgres_path (Database)"
    echo -e "  • $ORTHANC_DIR/*.json, *.yml (Configuration)"
    echo -e "${BLUE}💡 Run './orthanc_manager.sh start' to recreate containers with existing data${NC}"
}

# Function to purge (complete removal)
purge_installation() {
    local dicom_path=$(detect_dicom_storage_path)
    local postgres_path=$(detect_postgres_data_path)
    
    echo -e "${RED}🚨 DANGER: This will completely remove Orthanc and ALL data!${NC}"
    echo -e "${RED}This action cannot be undone!${NC}"
    echo -e ""
    echo -e "${YELLOW}What will be removed:${NC}"
    echo -e "  • All Docker containers and images"
    echo -e "  • All DICOM files ($dicom_path)"
    echo -e "  • Database data ($postgres_path)" 
    echo -e "  • Configuration files ($ORTHANC_DIR)"
    echo -e "  • Backups ($BACKUP_DIR)"
    echo -e ""
    echo -e "${RED}Type 'DELETE EVERYTHING' to confirm complete removal: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE EVERYTHING" ]]; then
        echo -e "${GREEN}✅ Purge cancelled - nothing was deleted${NC}"
        return
    fi
    
    echo -e "${YELLOW}Creating final backup before purge...${NC}"
    create_backup
    local final_backup=$(ls -t "$BACKUP_DIR"/ | head -1)
    echo -e "${GREEN}Final backup saved: $BACKUP_DIR/$final_backup${NC}"
    
    echo -e "${RED}🗑️  Beginning complete removal...${NC}"
    
    # Stop and remove everything
    if [[ -f "$ORTHANC_DIR/docker-compose.yml" ]]; then
        cd "$ORTHANC_DIR"
        echo -e "${YELLOW}Stopping containers...${NC}"
        docker compose down --volumes --remove-orphans --rmi all 2>/dev/null || true
    fi
    
    # Remove Docker networks (if created by this installation)
    echo -e "${YELLOW}Cleaning up Docker networks...${NC}"
    docker network rm orthanc_default 2>/dev/null || true
    
    # Remove all data using detected paths
    echo -e "${YELLOW}Removing DICOM storage: $dicom_path...${NC}"
    rm -rf "$dicom_path"
    
    echo -e "${YELLOW}Removing PostgreSQL data: $postgres_path...${NC}"
    rm -rf "$postgres_path"
    
    echo -e "${YELLOW}Removing configuration files...${NC}"
    rm -f "$ORTHANC_DIR/docker-compose.yml"
    rm -f "$ORTHANC_DIR/orthanc.json"
    rm -f "$ORTHANC_DIR/nginx.conf"
    rm -f "$ORTHANC_DIR/.db_password"
    rm -rf "$ORTHANC_DIR/lua-scripts"
    
    # Remove main directory if empty
    if [[ -d "$ORTHANC_DIR" ]]; then
        rmdir "$ORTHANC_DIR" 2>/dev/null || {
            echo -e "${YELLOW}⚠️  $ORTHANC_DIR not empty, leaving directory${NC}"
            echo -e "${BLUE}Remaining files:${NC}"
            ls -la "$ORTHANC_DIR"
        }
    fi
    
    echo -e "${GREEN}✅ Orthanc completely removed${NC}"
    echo -e "${BLUE}💡 Final backup preserved at: $BACKUP_DIR/$final_backup${NC}"
    echo -e "${BLUE}💡 Run install_orthanc.sh to reinstall${NC}"
}

# Function to show disk usage
show_disk_usage() {
    local dicom_path=$(detect_dicom_storage_path)
    local postgres_path=$(detect_postgres_data_path)
    
    echo -e "${BLUE}💾 Orthanc Disk Usage:${NC}"
    echo -e "${YELLOW}Storage Paths:${NC}"
    echo -e "  • DICOM Storage: $dicom_path"
    echo -e "  • PostgreSQL Data: $postgres_path"
    echo -e "  • Configuration: $ORTHANC_DIR"
    
    echo -e "\n${YELLOW}Disk Usage:${NC}"
    if [[ -d "$ORTHANC_DIR" ]]; then
        echo -e "  Installation Directory: $(du -sh "$ORTHANC_DIR" 2>/dev/null | cut -f1 || echo "N/A")"
    fi
    
    if [[ -d "$dicom_path" ]]; then
        echo -e "  DICOM Files: $(du -sh "$dicom_path" 2>/dev/null | cut -f1 || echo "N/A")"
        
        # Show DICOM file count if directory exists
        local dicom_count=$(find "$dicom_path" -name "*.dcm" 2>/dev/null | wc -l || echo "0")
        if [[ $dicom_count -gt 0 ]]; then
            echo -e "  DICOM File Count: $dicom_count files"
        fi
    else
        echo -e "  DICOM Files: Directory not found"
    fi
    
    if [[ -d "$postgres_path" ]]; then
        echo -e "  Database: $(du -sh "$postgres_path" 2>/dev/null | cut -f1 || echo "N/A")"
    else
        echo -e "  Database: Directory not found"
    fi
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo -e "  Backups: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "N/A")"
        echo -e "  Backup Count: $(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l) backups"
    fi
    
    echo -e "\n${YELLOW}Docker Images:${NC}"
    echo -e "$(docker images | grep -E "(orthanc|postgres|ohif)" | awk '{print "  " \$1 ":" \$2 " - " \$7}' 2>/dev/null || echo "  No Orthanc-related images found")"
    
# Check if DICOM storage is on a network mount
    if mountpoint -q "$dicom_path" 2>/dev/null || [[ "$dicom_path" =~ ^/mnt/ ]] || [[ "$dicom_path" =~ ^/media/ ]] || [[ "$dicom_path" =~ ^/data ]]; then
        echo -e "\n${BLUE}🌐 Network Storage Info:${NC}"
        echo -e "  • DICOM storage appears to be on a network/mounted drive"
        echo -e "  • Mount point: $(df "$dicom_path" 2>/dev/null | tail -1 | awk '{print $1}' || echo "Unknown")"
        echo -e "  • File system: $(df -T "$dicom_path" 2>/dev/null | tail -1 | awk '{print $2}' || echo "Unknown")"
        
        # Check mount status
        if mountpoint -q "$dicom_path" 2>/dev/null; then
            echo -e "  • Status: ${GREEN}✅ Properly mounted${NC}"
        else
            echo -e "  • Status: ${YELLOW}⚠️  Not detected as mount point${NC}"
        fi
    fi
}

# Function to clean old backups
clean_backups() {
    echo -e "${YELLOW}🧹 Cleaning old backups...${NC}"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${YELLOW}No backup directory found${NC}"
        return
    fi
    
    local backup_count=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l)
    echo -e "${BLUE}Current backups: $backup_count${NC}"
    
    if [[ $backup_count -le 5 ]]; then
        echo -e "${GREEN}✅ No cleanup needed (keeping up to 5 backups)${NC}"
        return
    fi
    
    echo -e "${YELLOW}Keeping 5 most recent backups, removing older ones...${NC}"
    
    # Keep only the 5 newest backups
    ls -t "$BACKUP_DIR"/ | tail -n +6 | while read -r old_backup; do
        if [[ -d "$BACKUP_DIR/$old_backup" ]]; then
            echo -e "  Removing: $old_backup"
            rm -rf "$BACKUP_DIR/$old_backup"
        fi
    done
    
    local new_count=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l)
    echo -e "${GREEN}✅ Cleanup complete. Backups: $backup_count → $new_count${NC}"
}

# Function to validate storage paths
validate_storage_paths() {
    local dicom_path=$(detect_dicom_storage_path)
    local postgres_path=$(detect_postgres_data_path)
    
    echo -e "${BLUE}🔍 Validating Storage Paths:${NC}"
    
    # Check DICOM storage
    if [[ -d "$dicom_path" ]]; then
        if [[ -w "$dicom_path" ]]; then
            echo -e "  • DICOM Storage: ${GREEN}✅ $dicom_path (writable)${NC}"
        else
            echo -e "  • DICOM Storage: ${YELLOW}⚠️  $dicom_path (not writable)${NC}"
        fi
    else
        echo -e "  • DICOM Storage: ${RED}❌ $dicom_path (does not exist)${NC}"
    fi
    
    # Check PostgreSQL data
    if [[ -d "$postgres_path" ]]; then
        echo -e "  • PostgreSQL Data: ${GREEN}✅ $postgres_path (exists)${NC}"
    else
        echo -e "  • PostgreSQL Data: ${YELLOW}⚠️  $postgres_path (does not exist)${NC}"
    fi
    
    # Check configuration directory
    if [[ -d "$ORTHANC_DIR" ]]; then
        if [[ -w "$ORTHANC_DIR" ]]; then
            echo -e "  • Configuration: ${GREEN}✅ $ORTHANC_DIR (writable)${NC}"
        else
            echo -e "  • Configuration: ${YELLOW}⚠️  $ORTHANC_DIR (not writable)${NC}"
        fi
    else
        echo -e "  • Configuration: ${RED}❌ $ORTHANC_DIR (does not exist)${NC}"
    fi
}

# Function to migrate storage (if paths change)
migrate_storage() {
    echo -e "${YELLOW}🚚 Storage Migration Tool${NC}"
    echo -e "${BLUE}This tool helps migrate DICOM storage to a new location${NC}"
    
    local current_dicom_path=$(detect_dicom_storage_path)
    
    echo -e "\n${YELLOW}Current DICOM storage path: $current_dicom_path${NC}"
    echo -e "${YELLOW}Enter new DICOM storage path (or press Enter to cancel): ${NC}"
    read -r new_path
    
    if [[ -z "$new_path" ]]; then
        echo -e "${YELLOW}Migration cancelled${NC}"
        return
    fi
    
    # Validate new path
    if [[ ! -d "$new_path" ]]; then
        echo -e "${YELLOW}Directory doesn't exist. Create it? (yes/no): ${NC}"
        read -r create_confirm
        if [[ "$create_confirm" == "yes" ]]; then
            mkdir -p "$new_path" || {
                echo -e "${RED}❌ Failed to create directory${NC}"
                return
            }
        else
            echo -e "${YELLOW}Migration cancelled${NC}"
            return
        fi
    fi
    
    # Check if new path is writable
    if [[ ! -w "$new_path" ]]; then
        echo -e "${RED}❌ New path is not writable: $new_path${NC}"
        return
    fi
    
    echo -e "${YELLOW}⚠️  This will:${NC}"
    echo -e "  • Stop Orthanc services"
    echo -e "  • Copy all DICOM data from $current_dicom_path to $new_path"
    echo -e "  • Update docker-compose.yml"
    echo -e "  • Restart services"
    echo -e "${YELLOW}Continue? (yes/no): ${NC}"
    read -r migrate_confirm
    
    if [[ "$migrate_confirm" != "yes" ]]; then
        echo -e "${YELLOW}Migration cancelled${NC}"
        return
    fi
    
    # Create backup first
    echo -e "${YELLOW}Creating backup before migration...${NC}"
    create_backup
    
    # Stop services
    echo -e "${YELLOW}Stopping services...${NC}"
    cd "$ORTHANC_DIR"
    docker compose stop
    
    # Copy data
    echo -e "${YELLOW}Copying DICOM data...${NC}"
    if [[ -d "$current_dicom_path" ]] && [[ "$(ls -A "$current_dicom_path" 2>/dev/null)" ]]; then
        cp -r "$current_dicom_path"/* "$new_path/" || {
            echo -e "${RED}❌ Failed to copy data${NC}"
            docker compose start
            return
        }
        echo -e "${GREEN}✅ Data copied successfully${NC}"
    else
        echo -e "${YELLOW}⚠️  No data found in current storage directory${NC}"
    fi
    
    # Update docker-compose.yml
    echo -e "${YELLOW}Updating configuration...${NC}"
    sed -i "s|device: '$current_dicom_path'|device: '$new_path'|g" "$ORTHANC_DIR/docker-compose.yml"
    
    # Restart services
    echo -e "${YELLOW}Restarting services...${NC}"
    docker compose down --volumes  # Remove old volume bindings
    docker compose up -d
    
    echo -e "${GREEN}✅ Migration completed${NC}"
    echo -e "${BLUE}New DICOM storage location: $new_path${NC}"
    
    # Verify migration
    sleep 10
    show_status
    
    echo -e "\n${YELLOW}⚠️  If everything is working correctly, you can remove the old data:${NC}"
    echo -e "  rm -rf $current_dicom_path"
}

# Main script logic
main() {
    local command="$1"
    
    case "$command" in
        "start")
            check_installation
            start_services
            ;;
        "stop")
            check_installation
            stop_services
            ;;
        "restart")
            check_installation
            restart_services
            ;;
        "status")
            check_installation
            show_status
            ;;
        "logs")
            check_installation
            show_logs
            ;;
        "update")
            check_installation
            update_config
            ;;
        "backup")
            check_installation
            create_backup
            ;;
        "restore")
            check_installation
            restore_backup
            ;;
        "delete")
            check_installation
            delete_installation
            ;;
        "purge")
            purge_installation
            ;;
        "usage"|"disk")
            check_installation
            show_disk_usage
            ;;
        "clean")
            clean_backups
            ;;
        "validate")
            check_installation
            validate_storage_paths
            ;;
        "migrate")
            check_installation
            migrate_storage
            ;;
        "help"|"-h"|"--help"|"")
            show_usage
            ;;
        *)
            echo -e "${RED}❌ Unknown command: $command${NC}"
            echo -e ""
            show_usage
            exit 1
            ;;
    esac
}

# Run the script
main "$@"