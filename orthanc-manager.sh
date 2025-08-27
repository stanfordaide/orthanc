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

# Function to print usage
show_usage() {
    echo -e "${CYAN}🏥 Orthanc Management Script${NC}"
    echo -e "${YELLOW}Usage: \$0 [command]${NC}"
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
    echo -e "  ${YELLOW}delete${NC}    - Stop and remove containers (keep data)"
    echo -e "  ${RED}purge${NC}     - Complete removal (containers + data + config)"
    echo -e ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  \$0 start"
    echo -e "  \$0 logs"
    echo -e "  \$0 backup"
    echo -e "  \$0 update"
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
    docker-compose up -d
    echo -e "${GREEN}✅ Services started${NC}"
    
    echo -e "${YELLOW}⏳ Waiting for services to initialize...${NC}"
    sleep 10
    show_status
}

# Function to stop services
stop_services() {
    echo -e "${YELLOW}🛑 Stopping Orthanc services...${NC}"
    cd "$ORTHANC_DIR"
    docker-compose stop
    echo -e "${GREEN}✅ Services stopped${NC}"
}

# Function to restart services
restart_services() {
    echo -e "${YELLOW}🔄 Restarting Orthanc services...${NC}"
    cd "$ORTHANC_DIR"
    docker-compose restart
    echo -e "${GREEN}✅ Services restarted${NC}"
    
    echo -e "${YELLOW}⏳ Waiting for services to initialize...${NC}"
    sleep 10
    show_status
}

# Function to show status
show_status() {
    echo -e "${BLUE}📊 Orthanc Service Status:${NC}"
    cd "$ORTHANC_DIR"
    docker-compose ps
    
    echo -e "\n${BLUE}🌐 Service URLs:${NC}"
    echo -e "  • Orthanc Web UI: http://localhost:8042"
    echo -e "  • OHIF Viewer: http://localhost:8008"
    echo -e "  • DICOM Port: 4242"
    echo -e "  • PostgreSQL: localhost:5433"
    
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
    docker-compose logs -f
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
    
    # Backup current config
    backup_config
    
    # Stop services
    echo -e "${YELLOW}Stopping services for update...${NC}"
    cd "$ORTHANC_DIR"
    docker-compose stop
    
    # Copy new configuration files
    echo -e "${YELLOW}Copying updated configuration...${NC}"
    cp "$SCRIPT_DIR/docker-compose.yml" "$ORTHANC_DIR/"
    cp "$SCRIPT_DIR/orthanc.json" "$ORTHANC_DIR/"
    cp "$SCRIPT_DIR/nginx.conf" "$ORTHANC_DIR/"
    
    if [[ -d "$SCRIPT_DIR/lua-scripts" ]]; then
        cp -r "$SCRIPT_DIR/lua-scripts"/* "$ORTHANC_DIR/lua-scripts/" 2>/dev/null || true
    fi
    
    # Restart services
    echo -e "${YELLOW}Restarting with new configuration...${NC}"
    docker-compose up -d
    
    echo -e "${GREEN}✅ Configuration updated and services restarted${NC}"
    
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

# Function to create full backup
create_backup() {
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_path="$BACKUP_DIR/full_backup_$timestamp"
    
    echo -e "${YELLOW}💾 Creating full backup (data + config)...${NC}"
    
    mkdir -p "$backup_path"
    
    # Stop services for consistent backup
    echo -e "${YELLOW}Stopping services for backup...${NC}"
    cd "$ORTHANC_DIR"
    docker-compose stop
    
    # Backup configuration
    cp "$ORTHANC_DIR/docker-compose.yml" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/orthanc.json" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/nginx.conf" "$backup_path/" 2>/dev/null || true
    cp "$ORTHANC_DIR/.db_password" "$backup_path/" 2>/dev/null || true
    cp -r "$ORTHANC_DIR/lua-scripts" "$backup_path/" 2>/dev/null || true
    
    # Backup data directories
    echo -e "${YELLOW}Backing up DICOM storage...${NC}"
    cp -r "$ORTHANC_DIR/orthanc-storage" "$backup_path/" 2>/dev/null || true
    
    echo -e "${YELLOW}Backing up PostgreSQL data...${NC}"
    cp -r "$ORTHANC_DIR/postgres-data" "$backup_path/" 2>/dev/null || true
    
    # Create backup info file
    cat > "$backup_path/backup_info.txt" << EOF
Backup Created: $(date)
Orthanc Version: $(docker image ls jodogne/orthanc-python --format "table {{.Tag}}" | tail -n +2 | head -1)
PostgreSQL Version: $(docker image ls postgres --format "table {{.Tag}}" | tail -n +2 | head -1)
Backup Type: Full (Configuration + Data)
EOF
    
    # Restart services
    echo -e "${YELLOW}Restarting services...${NC}"
    docker-compose start
    
    echo -e "${GREEN}✅ Full backup created: $backup_path${NC}"
    echo -e "${YELLOW}Backup size: $(du -sh "$backup_path" | cut -f1)${NC}"
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

# Function to restore from specific path
restore_from_path() {
    local backup_path="\$1"
    
    echo -e "${YELLOW}🔄 Restoring from backup: $(basename "$backup_path")${NC}"
    
    # Stop services
    cd "$ORTHANC_DIR"
    docker-compose down
    
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
    
    # Restore data if available
    if [[ -d "$backup_path/orthanc-storage" ]]; then
        echo -e "${YELLOW}Restoring DICOM storage...${NC}"
        rm -rf "$ORTHANC_DIR/orthanc-storage"
        cp -r "$backup_path/orthanc-storage" "$ORTHANC_DIR/"
    fi
    
    if [[ -d "$backup_path/postgres-data" ]]; then
        echo -e "${YELLOW}Restoring PostgreSQL data...${NC}"
        rm -rf "$ORTHANC_DIR/postgres-data"
        cp -r "$backup_path/postgres-data" "$ORTHANC_DIR/"
        chown -R 999:999 "$ORTHANC_DIR/postgres-data"
    fi
    
    # Start services
    echo -e "${YELLOW}Starting restored services...${NC}"
    docker-compose up -d
    
    echo -e "${GREEN}✅ Restore completed${NC}"
    
    sleep 10
    show_status
}

# Function to delete (remove containers, keep data)
delete_installation() {
    echo -e "${YELLOW}⚠️  This will stop and remove Orthanc containers but keep data${NC}"
    echo -e "${YELLOW}Are you sure? (yes/no): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}Delete cancelled${NC}"
        return
    fi
    
    echo -e "${YELLOW}🗑️  Removing Orthanc containers...${NC}"
    
    cd "$ORTHANC_DIR"
    
    # Stop and remove containers
    docker-compose down
    
    # Remove any orphaned containers
    docker-compose down --remove-orphans
    
    # Remove images (optional - comment out if you want to keep images)
    echo -e "${YELLOW}Removing Docker images...${NC}"
    docker-compose down --rmi all 2>/dev/null || true
    
    echo -e "${GREEN}✅ Containers removed${NC}"
    echo -e "${YELLOW}📁 Data preserved in:${NC}"
    echo -e "  • $ORTHANC_DIR/orthanc-storage (DICOM files)"
    echo -e "  • $ORTHANC_DIR/postgres-data (Database)"
    echo -e "  • $ORTHANC_DIR/*.json, *.yml (Configuration)"
    echo -e "${BLUE}💡 Run './orthanc_manager.sh start' to recreate containers with existing data${NC}"
}

# Function to purge (complete removal)
purge_installation() {
    echo -e "${RED}🚨 DANGER: This will completely remove Orthanc and ALL data!${NC}"
    echo -e "${RED}This action cannot be undone!${NC}"
    echo -e ""
    echo -e "${YELLOW}What will be removed:${NC}"
    echo -e "  • All Docker containers and images"
    echo -e "  • All DICOM files ($ORTHANC_DIR/orthanc-storage)"
    echo -e "  • Database data ($ORTHANC_DIR/postgres-data)" 
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
        docker-compose down --volumes --remove-orphans --rmi all 2>/dev/null || true
    fi
    
    # Remove Docker networks (if created by this installation)
    echo -e "${YELLOW}Cleaning up Docker networks...${NC}"
    docker network rm orthanc_default 2>/dev/null || true
    
    # Remove all data and configuration
    echo -e "${YELLOW}Removing data directories...${NC}"
    rm -rf "$ORTHANC_DIR/orthanc-storage"
    rm -rf "$ORTHANC_DIR/postgres-data"
    
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
    echo -e "${BLUE}💾 Orthanc Disk Usage:${NC}"
    
    if [[ -d "$ORTHANC_DIR" ]]; then
        echo -e "${YELLOW}Installation Directory:${NC}"
        echo -e "  Total: $(du -sh "$ORTHANC_DIR" 2>/dev/null | cut -f1 || echo "N/A")"
        
        if [[ -d "$ORTHANC_DIR/orthanc-storage" ]]; then
            echo -e "  DICOM Files: $(du -sh "$ORTHANC_DIR/orthanc-storage" 2>/dev/null | cut -f1 || echo "N/A")"
        fi
        
        if [[ -d "$ORTHANC_DIR/postgres-data" ]]; then
            echo -e "  Database: $(du -sh "$ORTHANC_DIR/postgres-data" 2>/dev/null | cut -f1 || echo "N/A")"
        fi
    fi
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo -e "${YELLOW}Backups:${NC}"
        echo -e "  Total: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "N/A")"
        echo -e "  Count: $(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l) backups"
    fi
    
    echo -e "${YELLOW}Docker Images:${NC}"
    echo -e "$(docker images | grep -E "(orthanc|postgres|ohif)" | awk '{print "  " $1 ":" $2 " - " $7}' 2>/dev/null || echo "  No Orthanc-related images found")"
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
            show_disk_usage
            ;;
        "clean")
            clean_backups
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