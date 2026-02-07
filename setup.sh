#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# ORTHANC SETUP SCRIPT
# ═══════════════════════════════════════════════════════════════════════════════
# First-time setup with customizable storage paths
#
# Usage:
#   ./setup.sh                                    # Interactive mode
#   ./setup.sh --dicom /mnt/nas/dicom --db /data/postgres  # Specify paths
#   ./setup.sh --defaults                         # Use all defaults
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────────
# LOAD DEFAULTS FROM config/env.defaults (authoritative source of all defaults)
# ─────────────────────────────────────────────────────────────────────────────────
ENV_DEFAULTS_FILE="$SCRIPT_DIR/config/env.defaults"

if [[ -f "$ENV_DEFAULTS_FILE" ]]; then
    # Load the defaults file
    set -a
    source "$ENV_DEFAULTS_FILE" 2>/dev/null || true
    set +a
fi

# Store as DEFAULT_* variables (these are the repo defaults)
DEFAULT_DICOM_STORAGE="${DICOM_STORAGE:-/opt/orthanc/orthanc-storage}"
DEFAULT_POSTGRES_STORAGE="${POSTGRES_STORAGE:-/opt/orthanc/postgres-data}"
DEFAULT_GRAFANA_STORAGE="${GRAFANA_STORAGE:-/opt/orthanc/grafana-data}"
DEFAULT_ORTHANC_AET="${ORTHANC_AET:-ORTHANC_LPCH}"
DEFAULT_ORTHANC_PASSWORD="${ORTHANC_PASSWORD:-helloaide123}"
DEFAULT_POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
DEFAULT_ORTHANC_USERNAME="${ORTHANC_USERNAME:-orthanc_admin}"
DEFAULT_POSTGRES_USER="${POSTGRES_USER:-orthanc}"
DEFAULT_OPERATOR_UI_PORT="${OPERATOR_UI_PORT:-8040}"
DEFAULT_ORTHANC_WEB_PORT="${ORTHANC_WEB_PORT:-8041}"
DEFAULT_OHIF_PORT="${OHIF_PORT:-8042}"
DEFAULT_POSTGRES_PORT="${POSTGRES_PORT:-8043}"
DEFAULT_ROUTING_API_PORT="${ROUTING_API_PORT:-8044}"
DEFAULT_GRAFANA_PORT="${GRAFANA_PORT:-8045}"
DEFAULT_DICOM_PORT="${DICOM_PORT:-4242}"
DEFAULT_TZ="${TZ:-America/Los_Angeles}"
DEFAULT_GRAFANA_USER="${GRAFANA_USER:-admin}"
DEFAULT_GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

# Mercure integration defaults (for AI processing tracking)
DEFAULT_MERCURE_DB_HOST="${MERCURE_DB_HOST:-mercure_db_1}"
DEFAULT_MERCURE_DB_PORT="${MERCURE_DB_PORT:-5432}"
DEFAULT_MERCURE_DB_NAME="${MERCURE_DB_NAME:-mercure}"
DEFAULT_MERCURE_DB_USER="${MERCURE_DB_USER:-mercure}"
DEFAULT_MERCURE_DB_PASS="${MERCURE_DB_PASS:-}"

# Clear working variables
unset DICOM_STORAGE POSTGRES_STORAGE GRAFANA_STORAGE ORTHANC_AET ORTHANC_PASSWORD ORTHANC_USERNAME
unset POSTGRES_USER POSTGRES_PASSWORD OPERATOR_UI_PORT ORTHANC_WEB_PORT OHIF_PORT
unset POSTGRES_PORT ROUTING_API_PORT GRAFANA_PORT DICOM_PORT TZ GRAFANA_USER GRAFANA_PASSWORD

# ─────────────────────────────────────────────────────────────────────────────────
# OVERLAY USER CONFIG FROM .env (if exists - this takes precedence!)
# ─────────────────────────────────────────────────────────────────────────────────
if [[ -f ".env" ]]; then
    # Source user's .env to override defaults
    set -a
    source .env 2>/dev/null || true
    set +a
    
    # Update defaults to match user's current config (for prompts)
    DEFAULT_DICOM_STORAGE="${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
    DEFAULT_POSTGRES_STORAGE="${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
    DEFAULT_GRAFANA_STORAGE="${GRAFANA_STORAGE:-$DEFAULT_GRAFANA_STORAGE}"
    DEFAULT_ORTHANC_AET="${ORTHANC_AET:-$DEFAULT_ORTHANC_AET}"
    DEFAULT_ORTHANC_PASSWORD="${ORTHANC_PASSWORD:-$DEFAULT_ORTHANC_PASSWORD}"
    DEFAULT_POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$DEFAULT_POSTGRES_PASSWORD}"
    
    # IMPORTANT: Preserve PostgreSQL password for existing databases
    SAVED_POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
    
    # Clear working variables (but keep saved PG password)
    unset DICOM_STORAGE POSTGRES_STORAGE GRAFANA_STORAGE ORTHANC_AET ORTHANC_PASSWORD
    
    # Restore PostgreSQL password (cannot change without breaking DB)
    POSTGRES_PASSWORD="$SAVED_POSTGRES_PASSWORD"
fi

# Parsed options
DICOM_STORAGE=""
POSTGRES_STORAGE=""
GRAFANA_STORAGE=""
ORTHANC_AET=""
ORTHANC_PASSWORD=""
POSTGRES_PASSWORD=""
USE_DEFAULTS=false
NON_INTERACTIVE=false
USE_EXISTING=false
FORCE_SETUP=false

# Backup/restore options
DO_BACKUP=false
DO_RESTORE=false
BACKUP_FILE=""
RESTORE_FILE=""
BACKUP_DIR="./backups"

# Interactive menu mode
INTERACTIVE_MENU=false
DO_SETUP=false

# ─────────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────────

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║   🏥  ORTHANC PACS SETUP                                     ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() { echo -e "${BLUE}ℹ${NC}  $1"; }
log_success() { echo -e "${GREEN}✓${NC}  $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC}  $1"; }
log_error() { echo -e "${RED}✗${NC}  $1"; }

# ─────────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MENU
# ─────────────────────────────────────────────────────────────────────────────────

show_interactive_menu() {
    while true; do
        clear
        print_banner
        
        # Show current status
        echo -e "${CYAN}Current Status:${NC}"
        if docker compose ps --status running 2>/dev/null | grep -q orthanc; then
            echo -e "  Services: ${GREEN}Running${NC}"
        else
            echo -e "  Services: ${YELLOW}Stopped${NC}"
        fi
        
        if [[ -f .env ]]; then
            source .env 2>/dev/null || true
            echo -e "  DICOM Storage: ${YELLOW}${DICOM_STORAGE:-not set}${NC}"
            echo -e "  PostgreSQL:    ${YELLOW}${POSTGRES_STORAGE:-not set}${NC}"
        else
            echo -e "  Config: ${YELLOW}Not configured${NC}"
        fi
        
        # Show disk usage
        local root_usage=$(df / 2>/dev/null | tail -1 | awk '{print $5}')
        echo -e "  Root Disk: ${root_usage:-unknown}"
        echo
        
        echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}  MAIN MENU${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
        echo
        echo -e "  ${CYAN}SETUP & CONFIGURATION${NC}"
        echo -e "    ${YELLOW}1${NC}) Install / Update (preserves existing data)"
        echo -e "    ${YELLOW}2${NC}) Change Storage Locations"
        echo -e "    ${YELLOW}3${NC}) Change Credentials"
        echo -e "    ${YELLOW}4${NC}) Configure DICOM Modalities"
        echo
        echo -e "  ${CYAN}SERVICE MANAGEMENT${NC}"
        echo -e "    ${YELLOW}5${NC}) Start Services"
        echo -e "    ${YELLOW}6${NC}) Stop Services"
        echo -e "    ${YELLOW}7${NC}) Restart Services"
        echo -e "    ${YELLOW}8${NC}) View Logs"
        echo -e "    ${YELLOW}9${NC}) Check Status"
        echo
        echo -e "  ${CYAN}BACKUP & RESTORE${NC}"
        echo -e "    ${YELLOW}b${NC}) Backup Data"
        echo -e "    ${YELLOW}r${NC}) Restore from Backup"
        echo -e "    ${YELLOW}l${NC}) List Backups"
        echo
        echo -e "  ${CYAN}MAINTENANCE${NC}"
        echo -e "    ${YELLOW}u${NC}) Upgrade (Pull Latest Images)"
        echo -e "    ${YELLOW}c${NC}) Clean (Remove Containers, Keep Data)"
        echo -e "    ${YELLOW}d${NC}) Delete Everything (⚠️  Destructive!)"
        echo
        echo -e "    ${YELLOW}q${NC}) Quit"
        echo
        echo -n "  Select option: "
        
        read -r choice
        
        case "$choice" in
            1)
                clear
                do_fresh_setup
                echo
                read -p "Press Enter to continue..."
                ;;
            2)
                clear
                do_change_storage
                echo
                read -p "Press Enter to continue..."
                ;;
            3)
                clear
                do_change_credentials
                echo
                read -p "Press Enter to continue..."
                ;;
            4)
                clear
                do_configure_modalities
                echo
                read -p "Press Enter to continue..."
                ;;
            5)
                clear
                echo -e "${BLUE}Starting services...${NC}"
                docker compose up -d
                echo
                log_success "Services started"
                echo
                read -p "Press Enter to continue..."
                ;;
            6)
                clear
                echo -e "${BLUE}Stopping services...${NC}"
                docker compose stop
                echo
                log_success "Services stopped"
                echo
                read -p "Press Enter to continue..."
                ;;
            7)
                clear
                echo -e "${BLUE}Restarting services...${NC}"
                docker compose restart
                echo
                log_success "Services restarted"
                echo
                read -p "Press Enter to continue..."
                ;;
            8)
                clear
                echo -e "${BLUE}Viewing logs (Ctrl+C to exit)...${NC}"
                echo
                docker compose logs -f --tail=100 || true
                ;;
            9)
                clear
                echo -e "${BLUE}Service Status:${NC}"
                echo
                docker compose ps -a
                echo
                if [[ -f .env ]]; then
                    source .env
                    echo -e "\n${CYAN}Access URLs:${NC}"
                    echo -e "  Dashboard: http://localhost:${OPERATOR_UI_PORT:-8040}"
                    echo -e "  Orthanc:   http://localhost:${ORTHANC_WEB_PORT:-8041}"
                    echo -e "  OHIF:      http://localhost:${OHIF_PORT:-8042}"
                    echo -e "  Grafana:   http://localhost:${GRAFANA_PORT:-8045}"
                fi
                echo
                read -p "Press Enter to continue..."
                ;;
            b|B)
                clear
                do_backup
                echo
                read -p "Press Enter to continue..."
                ;;
            r|R)
                clear
                do_interactive_restore
                echo
                read -p "Press Enter to continue..."
                ;;
            l|L)
                clear
                echo -e "${BLUE}Available Backups:${NC}"
                echo
                if ls backups/*.tar.gz 2>/dev/null; then
                    ls -lah backups/*.tar.gz
                else
                    echo "  No backups found in ./backups/"
                fi
                echo
                read -p "Press Enter to continue..."
                ;;
            u|U)
                clear
                echo -e "${BLUE}Upgrading services...${NC}"
                docker compose pull
                docker compose up -d
                echo
                log_success "Upgrade complete"
                echo
                read -p "Press Enter to continue..."
                ;;
            c|C)
                clear
                echo -e "${YELLOW}This will remove containers but keep your data.${NC}"
                read -p "Continue? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy] ]]; then
                    docker compose down
                    log_success "Containers removed. Data preserved."
                fi
                echo
                read -p "Press Enter to continue..."
                ;;
            d|D)
                clear
                do_interactive_delete
                echo
                read -p "Press Enter to continue..."
                ;;
            q|Q)
                clear
                echo "Goodbye!"
                exit 0
                ;;
            *)
                echo
                log_warn "Invalid option: $choice"
                sleep 1
                ;;
        esac
    done
}

do_fresh_setup() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  INSTALL / UPDATE${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    # Run the normal setup flow
    NON_INTERACTIVE=false
    check_existing
    collect_config
    show_summary
    
    echo
    read -p "Proceed with setup? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Setup cancelled."
        return
    fi
    
    echo
    create_env_file
    update_orthanc_json
    create_directories
    make_executable
    start_services
    if [[ $? -eq 0 ]]; then
        seed_modalities
    fi
    print_completion
}

do_change_storage() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CHANGE STORAGE LOCATIONS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    # Load current config
    if [[ -f .env ]]; then
        source .env
    fi
    
    local current_dicom="${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
    local current_postgres="${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
    
    echo -e "${CYAN}Current Storage Locations:${NC}"
    echo "  DICOM:      $current_dicom"
    echo "  PostgreSQL: $current_postgres"
    echo
    
    # Show disk space
    echo -e "${CYAN}Disk Space:${NC}"
    df -h / /home 2>/dev/null | head -5
    echo
    
    echo -e "${YELLOW}Enter new storage locations (or press Enter to keep current):${NC}"
    echo
    
    read -p "DICOM storage path [$current_dicom]: " new_dicom
    new_dicom="${new_dicom:-$current_dicom}"
    
    read -p "PostgreSQL data path [$current_postgres]: " new_postgres
    new_postgres="${new_postgres:-$current_postgres}"
    
    if [[ "$new_dicom" == "$current_dicom" && "$new_postgres" == "$current_postgres" ]]; then
        log_info "No changes made."
        return
    fi
    
    echo
    echo -e "${YELLOW}⚠️  Changing storage locations requires:${NC}"
    echo "  1. Stopping services"
    echo "  2. Moving data to new location"
    echo "  3. Updating configuration"
    echo "  4. Restarting services"
    echo
    echo -e "${CYAN}Options:${NC}"
    echo "  1) Backup first, then move (recommended)"
    echo "  2) Move data directly"
    echo "  3) Start fresh at new location (loses existing data)"
    echo "  4) Cancel"
    echo
    read -p "Choose option [1-4]: " move_option
    
    case "$move_option" in
        1)
            echo
            log_info "Creating backup first..."
            do_backup
            echo
            DICOM_STORAGE="$new_dicom"
            POSTGRES_STORAGE="$new_postgres"
            log_info "Restoring to new location..."
            RESTORE_FILE=$(ls -t backups/*.tar.gz 2>/dev/null | head -1)
            if [[ -n "$RESTORE_FILE" ]]; then
                do_restore
            else
                log_error "No backup file found"
            fi
            ;;
        2)
            echo
            log_info "Stopping services..."
            docker compose down
            
            log_info "Moving DICOM data..."
            sudo mkdir -p "$new_dicom"
            sudo mv "$current_dicom"/* "$new_dicom/" 2>/dev/null || true
            sudo chown -R 1000:1000 "$new_dicom"
            
            log_info "Moving PostgreSQL data..."
            sudo mkdir -p "$new_postgres"
            sudo mv "$current_postgres"/* "$new_postgres/" 2>/dev/null || true
            sudo chown -R 999:999 "$new_postgres"
            
            log_info "Updating configuration..."
            sed -i "s|^DICOM_STORAGE=.*|DICOM_STORAGE=$new_dicom|" .env
            sed -i "s|^POSTGRES_STORAGE=.*|POSTGRES_STORAGE=$new_postgres|" .env
            
            log_info "Starting services..."
            docker compose up -d
            
            log_success "Storage locations changed successfully!"
            ;;
        3)
            echo
            log_warn "This will lose all existing data!"
            read -p "Are you sure? Type 'DELETE' to confirm: " confirm
            if [[ "$confirm" == "DELETE" ]]; then
                docker compose down
                DICOM_STORAGE="$new_dicom"
                POSTGRES_STORAGE="$new_postgres"
                create_env_file
                create_directories
                docker compose up -d
                log_success "Fresh start at new location!"
            else
                log_info "Cancelled."
            fi
            ;;
        *)
            log_info "Cancelled."
            ;;
    esac
}

do_change_credentials() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CHANGE CREDENTIALS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    if [[ -f .env ]]; then
        source .env
    fi
    
    echo -e "${CYAN}Current Credentials:${NC}"
    echo "  Orthanc Username: ${ORTHANC_USERNAME:-orthanc_admin}"
    echo "  Orthanc Password: ${ORTHANC_PASSWORD:-<not set>}"
    echo "  PostgreSQL User:  ${POSTGRES_USER:-orthanc}"
    echo "  PostgreSQL Pass:  ${POSTGRES_PASSWORD:-<not set>}"
    echo
    
    echo -e "${YELLOW}What would you like to change?${NC}"
    echo "  1) Orthanc admin password"
    echo "  2) Generate new passwords for everything"
    echo "  3) Cancel"
    echo
    read -p "Choose option [1-3]: " cred_option
    
    case "$cred_option" in
        1)
            echo
            read -s -p "New Orthanc password: " new_pass
            echo
            read -s -p "Confirm password: " confirm_pass
            echo
            
            if [[ "$new_pass" != "$confirm_pass" ]]; then
                log_error "Passwords don't match!"
                return
            fi
            
            ORTHANC_PASSWORD="$new_pass"
            sed -i "s|^ORTHANC_PASSWORD=.*|ORTHANC_PASSWORD=$new_pass|" .env
            update_orthanc_json
            
            log_info "Restarting Orthanc to apply changes..."
            docker compose restart orthanc
            
            log_success "Orthanc password changed!"
            ;;
        2)
            echo
            local new_orthanc_pass=$(generate_password)
            local new_postgres_pass=$(generate_password)
            
            ORTHANC_PASSWORD="$new_orthanc_pass"
            POSTGRES_PASSWORD="$new_postgres_pass"
            
            log_warn "This will require recreating the database!"
            read -p "Continue? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy] ]]; then
                return
            fi
            
            sed -i "s|^ORTHANC_PASSWORD=.*|ORTHANC_PASSWORD=$new_orthanc_pass|" .env
            sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$new_postgres_pass|" .env
            update_orthanc_json
            
            log_info "New credentials generated:"
            echo "  Orthanc:    orthanc_admin / $new_orthanc_pass"
            echo "  PostgreSQL: orthanc / $new_postgres_pass"
            
            log_warn "You'll need to recreate the database for PostgreSQL password change."
            ;;
        *)
            log_info "Cancelled."
            ;;
    esac
}

do_configure_modalities() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CONFIGURE DICOM MODALITIES${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    if [[ -f .env ]]; then
        source .env
    fi
    
    local orthanc_url="http://localhost:${ORTHANC_WEB_PORT:-8041}"
    local auth="${ORTHANC_USERNAME:-orthanc_admin}:${ORTHANC_PASSWORD:-helloaide123}"
    
    # Check if Orthanc is running
    if ! curl -s -u "$auth" "$orthanc_url/system" &>/dev/null; then
        log_error "Orthanc is not running. Start services first."
        return
    fi
    
    echo -e "${CYAN}Current DICOM Modalities:${NC}"
    echo
    local modalities=$(curl -s -u "$auth" "$orthanc_url/modalities" 2>/dev/null)
    if [[ -n "$modalities" && "$modalities" != "[]" ]]; then
        for mod in $(echo "$modalities" | tr -d '[]"' | tr ',' ' '); do
            local details=$(curl -s -u "$auth" "$orthanc_url/modalities/$mod" 2>/dev/null)
            echo "  $mod: $details"
        done
    else
        echo "  No modalities configured"
    fi
    echo
    
    echo -e "${YELLOW}Options:${NC}"
    echo "  1) Add new modality"
    echo "  2) Remove modality"
    echo "  3) Test modality (C-ECHO)"
    echo "  4) Reset to defaults"
    echo "  5) Back to menu"
    echo
    read -p "Choose option [1-5]: " mod_option
    
    case "$mod_option" in
        1)
            echo
            read -p "Modality name (e.g., WORKSTATION1): " mod_name
            read -p "AE Title: " mod_aet
            read -p "Host/IP: " mod_host
            read -p "Port: " mod_port
            
            local config="{\"AET\":\"$mod_aet\",\"Host\":\"$mod_host\",\"Port\":$mod_port,\"AllowEcho\":true,\"AllowStore\":true}"
            
            if curl -s -u "$auth" -X PUT "$orthanc_url/modalities/$mod_name" \
                -H "Content-Type: application/json" -d "$config" &>/dev/null; then
                log_success "Modality '$mod_name' added!"
            else
                log_error "Failed to add modality"
            fi
            ;;
        2)
            echo
            read -p "Modality name to remove: " mod_name
            if curl -s -u "$auth" -X DELETE "$orthanc_url/modalities/$mod_name" &>/dev/null; then
                log_success "Modality '$mod_name' removed!"
            else
                log_error "Failed to remove modality"
            fi
            ;;
        3)
            echo
            read -p "Modality name to test: " mod_name
            echo "Testing C-ECHO to $mod_name..."
            if curl -s -u "$auth" -X POST "$orthanc_url/modalities/$mod_name/echo" &>/dev/null; then
                log_success "C-ECHO successful!"
            else
                log_error "C-ECHO failed"
            fi
            ;;
        4)
            echo
            log_info "Resetting to default modalities..."
            seed_modalities
            ;;
        *)
            return
            ;;
    esac
}

do_interactive_restore() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  RESTORE FROM BACKUP${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    echo -e "${CYAN}Available Backups:${NC}"
    echo
    
    local backups=($(ls -t backups/*.tar.gz 2>/dev/null))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        log_warn "No backups found in ./backups/"
        echo
        read -p "Enter path to backup file: " custom_path
        if [[ -f "$custom_path" ]]; then
            RESTORE_FILE="$custom_path"
        else
            log_error "File not found: $custom_path"
            return
        fi
    else
        local i=1
        for backup in "${backups[@]}"; do
            local size=$(du -h "$backup" 2>/dev/null | cut -f1)
            local date=$(stat -c %y "$backup" 2>/dev/null | cut -d. -f1)
            echo "  $i) $(basename "$backup") ($size, $date)"
            i=$((i + 1))
        done
        echo
        read -p "Select backup [1-${#backups[@]}] or enter path: " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#backups[@]} ]]; then
            RESTORE_FILE="${backups[$((selection-1))]}"
        elif [[ -f "$selection" ]]; then
            RESTORE_FILE="$selection"
        else
            log_error "Invalid selection"
            return
        fi
    fi
    
    echo
    log_info "Selected: $RESTORE_FILE"
    echo
    
    # Ask about restore location
    if [[ -f .env ]]; then
        source .env
    fi
    
    echo -e "${YELLOW}Restore to:${NC}"
    echo "  1) Current location (${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE})"
    echo "  2) New location"
    echo
    read -p "Choose [1-2]: " loc_choice
    
    if [[ "$loc_choice" == "2" ]]; then
        read -p "New DICOM storage path: " DICOM_STORAGE
        read -p "New PostgreSQL data path: " POSTGRES_STORAGE
    fi
    
    do_restore
}

do_interactive_delete() {
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  ⚠️  DELETE EVERYTHING${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    if [[ -f .env ]]; then
        source .env
    fi
    
    echo -e "${YELLOW}This will permanently delete:${NC}"
    echo "  - All Docker containers and images"
    echo "  - DICOM storage: ${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
    echo "  - PostgreSQL data: ${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
    echo "  - Configuration files"
    echo
    
    echo -e "${RED}THIS CANNOT BE UNDONE!${NC}"
    echo
    read -p "Type 'DELETE EVERYTHING' to confirm: " confirm
    
    if [[ "$confirm" == "DELETE EVERYTHING" ]]; then
        echo
        log_info "Stopping and removing containers..."
        docker compose down -v 2>/dev/null || true
        
        log_info "Removing storage directories..."
        sudo rm -rf "${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}" 2>/dev/null || true
        sudo rm -rf "${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}" 2>/dev/null || true
        
        log_info "Removing configuration..."
        rm -f .env 2>/dev/null || true
        
        echo
        log_success "Everything deleted."
        echo "Run './setup.sh' to start fresh."
    else
        log_info "Cancelled. Nothing was deleted."
    fi
}

generate_password() {
    openssl rand -base64 24 | tr -d '/+=' | head -c 20
}

prompt() {
    local prompt_text="$1"
    local default_value="$2"
    local var_name="$3"
    
    if [[ "$NON_INTERACTIVE" == true ]]; then
        eval "$var_name=\"$default_value\""
        return
    fi
    
    if [[ -n "$default_value" ]]; then
        read -p "$prompt_text [$default_value]: " input
        eval "$var_name=\"${input:-$default_value}\""
    else
        read -p "$prompt_text: " input
        eval "$var_name=\"$input\""
    fi
}

prompt_password() {
    local prompt_text="$1"
    local var_name="$2"
    local default="$3"
    
    if [[ "$NON_INTERACTIVE" == true ]]; then
        if [[ -n "$default" ]]; then
            eval "$var_name=\"$default\""
        else
            eval "$var_name=\"$(generate_password)\""
        fi
        return
    fi
    
    echo -n "$prompt_text"
    if [[ -n "$default" ]]; then
        echo -n " [press Enter to keep current]: "
    else
        echo -n " [press Enter to generate]: "
    fi
    read -s input
    echo
    
    if [[ -z "$input" ]]; then
        if [[ -n "$default" ]]; then
            eval "$var_name=\"$default\""
        else
            local generated=$(generate_password)
            eval "$var_name=\"$generated\""
            log_info "Generated password: $generated"
        fi
    else
        eval "$var_name=\"$input\""
    fi
}

validate_path() {
    local path="$1"
    local name="$2"
    
    # Check if parent directory exists or can be created
    local parent_dir=$(dirname "$path")
    if [[ ! -d "$parent_dir" ]]; then
        log_warn "Parent directory doesn't exist: $parent_dir"
        return 1
    fi
    
    # Check if path exists
    if [[ -d "$path" ]]; then
        log_success "$name path exists: $path"
    else
        log_info "$name path will be created: $path"
    fi
    
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────────
# BACKUP AND RESTORE
# ─────────────────────────────────────────────────────────────────────────────────

do_backup() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ORTHANC BACKUP${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    # Load current config
    if [[ -f .env ]]; then
        source .env
    fi
    
    local dicom_path="${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
    local postgres_path="${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Generate backup filename if not specified
    if [[ -z "$BACKUP_FILE" ]]; then
        BACKUP_FILE="$BACKUP_DIR/orthanc-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    elif [[ ! "$BACKUP_FILE" =~ ^/ ]]; then
        # If relative path, put in backup dir
        BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILE"
    fi
    
    local backup_tmp=$(mktemp -d)
    local backup_name=$(basename "$BACKUP_FILE" .tar.gz)
    
    log_info "Creating backup: $BACKUP_FILE"
    log_info "DICOM storage: $dicom_path"
    log_info "PostgreSQL data: $postgres_path"
    
    # Check if services are running
    local services_running=false
    if docker compose ps --status running 2>/dev/null | grep -q orthanc; then
        services_running=true
    fi
    
    # Step 1: Backup PostgreSQL (if running, use pg_dump for consistency)
    log_info "Backing up PostgreSQL database..."
    mkdir -p "$backup_tmp/postgres"
    
    if [[ "$services_running" == true ]]; then
        # Use pg_dump for live backup
        if docker compose exec -T orthanc-db pg_dump -U orthanc orthanc > "$backup_tmp/postgres/orthanc.sql" 2>/dev/null; then
            log_success "Database dumped via pg_dump"
        else
            log_warn "pg_dump failed, copying data directory instead"
            if [[ -d "$postgres_path" ]]; then
                sudo cp -a "$postgres_path"/* "$backup_tmp/postgres/" 2>/dev/null || \
                    cp -a "$postgres_path"/* "$backup_tmp/postgres/"
            fi
        fi
    else
        # Services not running, copy data directory
        if [[ -d "$postgres_path" ]]; then
            log_info "Copying PostgreSQL data directory..."
            sudo cp -a "$postgres_path"/* "$backup_tmp/postgres/" 2>/dev/null || \
                cp -a "$postgres_path"/* "$backup_tmp/postgres/"
            log_success "PostgreSQL data copied"
        else
            log_warn "PostgreSQL data directory not found: $postgres_path"
        fi
    fi
    
    # Step 2: Backup DICOM storage
    log_info "Backing up DICOM storage..."
    mkdir -p "$backup_tmp/dicom"
    
    if [[ -d "$dicom_path" ]]; then
        local dicom_size=$(du -sh "$dicom_path" 2>/dev/null | cut -f1)
        log_info "DICOM storage size: $dicom_size"
        
        # Copy DICOM data
        sudo cp -a "$dicom_path"/* "$backup_tmp/dicom/" 2>/dev/null || \
            cp -a "$dicom_path"/* "$backup_tmp/dicom/" 2>/dev/null || true
        log_success "DICOM data copied"
    else
        log_warn "DICOM storage directory not found: $dicom_path"
    fi
    
    # Step 3: Backup configuration
    log_info "Backing up configuration..."
    mkdir -p "$backup_tmp/config"
    cp .env "$backup_tmp/config/" 2>/dev/null || true
    cp config/orthanc.json "$backup_tmp/config/" 2>/dev/null || true
    
    # Step 4: Create metadata file
    cat > "$backup_tmp/backup-info.txt" << EOF
Orthanc Backup
==============
Created: $(date)
Host: $(hostname)
DICOM Storage: $dicom_path
PostgreSQL Path: $postgres_path
Services Running: $services_running

Contents:
- postgres/   : PostgreSQL data or SQL dump
- dicom/      : DICOM storage files
- config/     : Configuration files (.env, orthanc.json)
EOF
    
    # Step 5: Create tarball
    log_info "Compressing backup..."
    cd "$backup_tmp"
    tar -czf "$BACKUP_FILE" . 2>/dev/null
    cd - > /dev/null
    
    # Cleanup
    rm -rf "$backup_tmp"
    
    local backup_size=$(du -sh "$BACKUP_FILE" 2>/dev/null | cut -f1)
    
    echo
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅  BACKUP COMPLETE                                          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "  Backup file: ${YELLOW}$BACKUP_FILE${NC}"
    echo -e "  Size: ${YELLOW}$backup_size${NC}"
    echo
    echo -e "  To restore: ${CYAN}./setup.sh --restore $BACKUP_FILE${NC}"
    echo
}

do_restore() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ORTHANC RESTORE${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    if [[ -z "$RESTORE_FILE" || ! -f "$RESTORE_FILE" ]]; then
        log_error "Backup file not found: $RESTORE_FILE"
        exit 1
    fi
    
    log_info "Restoring from: $RESTORE_FILE"
    
    # Load current or default config for target paths
    if [[ -f .env ]]; then
        source .env
    fi
    
    # Use command-line args if provided, otherwise use .env or defaults
    local dicom_path="${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
    local postgres_path="${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
    
    log_info "Target DICOM storage: $dicom_path"
    log_info "Target PostgreSQL data: $postgres_path"
    
    # Stop services if running
    if docker compose ps --status running 2>/dev/null | grep -q orthanc; then
        log_info "Stopping services..."
        docker compose down 2>/dev/null || true
    fi
    
    # Confirm restore
    if [[ "$NON_INTERACTIVE" != true ]]; then
        echo
        echo -e "${YELLOW}⚠️  This will overwrite existing data at:${NC}"
        echo "   - $dicom_path"
        echo "   - $postgres_path"
        echo
        read -p "Continue with restore? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            log_info "Restore cancelled"
            exit 0
        fi
    fi
    
    # Extract backup
    local restore_tmp=$(mktemp -d)
    log_info "Extracting backup..."
    tar -xzf "$RESTORE_FILE" -C "$restore_tmp"
    
    # Create target directories
    log_info "Creating target directories..."
    sudo mkdir -p "$dicom_path" "$postgres_path" 2>/dev/null || \
        mkdir -p "$dicom_path" "$postgres_path"
    
    # Restore PostgreSQL
    log_info "Restoring PostgreSQL data..."
    if [[ -f "$restore_tmp/postgres/orthanc.sql" ]]; then
        # SQL dump - need to start DB first and restore
        log_info "Found SQL dump, will restore after starting database"
        RESTORE_SQL="$restore_tmp/postgres/orthanc.sql"
    elif [[ -d "$restore_tmp/postgres" && "$(ls -A $restore_tmp/postgres 2>/dev/null)" ]]; then
        # Data directory copy
        sudo rm -rf "$postgres_path"/* 2>/dev/null || rm -rf "$postgres_path"/*
        sudo cp -a "$restore_tmp/postgres"/* "$postgres_path/" 2>/dev/null || \
            cp -a "$restore_tmp/postgres"/* "$postgres_path/"
        sudo chown -R 999:999 "$postgres_path" 2>/dev/null || \
            chown -R 999:999 "$postgres_path" 2>/dev/null || true
        log_success "PostgreSQL data restored"
    fi
    
    # Restore DICOM storage
    log_info "Restoring DICOM storage..."
    if [[ -d "$restore_tmp/dicom" && "$(ls -A $restore_tmp/dicom 2>/dev/null)" ]]; then
        sudo rm -rf "$dicom_path"/* 2>/dev/null || rm -rf "$dicom_path"/*
        sudo cp -a "$restore_tmp/dicom"/* "$dicom_path/" 2>/dev/null || \
            cp -a "$restore_tmp/dicom"/* "$dicom_path/"
        sudo chown -R 1000:1000 "$dicom_path" 2>/dev/null || \
            chown -R 1000:1000 "$dicom_path" 2>/dev/null || true
        log_success "DICOM storage restored"
    fi
    
    # Restore config if not overriding
    if [[ -f "$restore_tmp/config/.env" && ! -f .env ]]; then
        log_info "Restoring configuration..."
        cp "$restore_tmp/config/.env" .env
        cp "$restore_tmp/config/orthanc.json" config/orthanc.json 2>/dev/null || true
    fi
    
    # Update .env with new paths if specified
    if [[ -n "$DICOM_STORAGE" || -n "$POSTGRES_STORAGE" ]]; then
        log_info "Updating storage paths in .env..."
        if [[ -n "$DICOM_STORAGE" ]]; then
            sed -i "s|^DICOM_STORAGE=.*|DICOM_STORAGE=$DICOM_STORAGE|" .env
        fi
        if [[ -n "$POSTGRES_STORAGE" ]]; then
            sed -i "s|^POSTGRES_STORAGE=.*|POSTGRES_STORAGE=$POSTGRES_STORAGE|" .env
        fi
    fi
    
    # Start services
    log_info "Starting services..."
    docker compose up -d
    
    # Wait for DB to be ready
    log_info "Waiting for database to be ready..."
    sleep 10
    
    # If we have SQL dump, restore it now
    if [[ -n "${RESTORE_SQL:-}" && -f "$RESTORE_SQL" ]]; then
        log_info "Restoring SQL dump..."
        # Wait a bit more for DB
        sleep 5
        if docker compose exec -T orthanc-db psql -U orthanc orthanc < "$RESTORE_SQL" 2>/dev/null; then
            log_success "SQL dump restored"
        else
            log_warn "SQL restore may have had issues - check logs"
        fi
    fi
    
    # Cleanup
    rm -rf "$restore_tmp"
    
    echo
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅  RESTORE COMPLETE                                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "  DICOM storage: ${YELLOW}$dicom_path${NC}"
    echo -e "  PostgreSQL data: ${YELLOW}$postgres_path${NC}"
    echo
    echo -e "  Check status: ${CYAN}docker compose ps${NC}"
    echo -e "  View logs: ${CYAN}docker compose logs -f${NC}"
    echo
}

# ─────────────────────────────────────────────────────────────────────────────────
# PARSE ARGUMENTS
# ─────────────────────────────────────────────────────────────────────────────────

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

When run without options, shows an interactive menu.

INTERACTIVE MODE:
  $0                  Show interactive menu (recommended)
  $0 --menu           Same as above

DIRECT SETUP OPTIONS:
  --dicom PATH        DICOM storage path (default: $DEFAULT_DICOM_STORAGE)
  --db PATH           PostgreSQL data path (default: $DEFAULT_POSTGRES_STORAGE)
  --aet NAME          DICOM AE Title (default: $DEFAULT_ORTHANC_AET)
  --orthanc-pass PWD  Orthanc admin password (default: $DEFAULT_ORTHANC_PASSWORD)
  --db-pass PWD       PostgreSQL password (default: auto-generate)
  --defaults          Use all default values (non-interactive)
  --non-interactive   Skip all prompts
  --force             Overwrite existing configuration without prompting

BACKUP/RESTORE:
  --backup [FILE]     Backup DICOM data and database to file
  --restore FILE      Restore from backup file
  --backup-dir DIR    Directory to store backups (default: ./backups)

OTHER:
  -h, --help          Show this help

EXAMPLES:
  $0                                          # Interactive menu (recommended)
  $0 --defaults                               # Quick setup with defaults
  $0 --backup                                 # Create backup
  $0 --restore backups/orthanc-backup-*.tar.gz --dicom /home/orthanc/dicom

The interactive menu provides:
  - Fresh install / reconfigure
  - Change storage locations (with migration)
  - Change credentials
  - Manage DICOM modalities
  - Start/stop/restart services
  - Backup and restore
  - View logs and status
  - Complete uninstall

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dicom)
                DICOM_STORAGE="$2"
                shift 2
                ;;
            --db|--postgres)
                POSTGRES_STORAGE="$2"
                shift 2
                ;;
            --aet)
                ORTHANC_AET="$2"
                shift 2
                ;;
            --orthanc-pass)
                ORTHANC_PASSWORD="$2"
                shift 2
                ;;
            --db-pass|--postgres-pass)
                POSTGRES_PASSWORD="$2"
                shift 2
                ;;
            --defaults)
                USE_DEFAULTS=true
                NON_INTERACTIVE=true
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --force)
                FORCE_SETUP=true
                NON_INTERACTIVE=true
                shift
                ;;
            --backup)
                DO_BACKUP=true
                # Check if next arg is a filename (not another option)
                if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
                    BACKUP_FILE="$2"
                    shift
                fi
                shift
                ;;
            --restore)
                DO_RESTORE=true
                RESTORE_FILE="$2"
                shift 2
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --menu)
                INTERACTIVE_MENU=true
                shift
                ;;
            --setup)
                # Run setup flow directly (not full menu), interactive
                DO_SETUP=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Use environment variables if set and not overridden by args
    DICOM_STORAGE="${DICOM_STORAGE:-${DICOM_STORAGE_ENV:-}}"
    POSTGRES_STORAGE="${POSTGRES_STORAGE:-${POSTGRES_STORAGE_ENV:-}}"
    ORTHANC_AET="${ORTHANC_AET:-${ORTHANC_AET_ENV:-}}"
    ORTHANC_PASSWORD="${ORTHANC_PASSWORD:-${ORTHANC_PASSWORD_ENV:-}}"
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_PASSWORD_ENV:-}}"
}

# ─────────────────────────────────────────────────────────────────────────────────
# EXISTING INSTALLATION CHECK
# ─────────────────────────────────────────────────────────────────────────────────

count_studies() {
    local storage_path="$1"
    if [[ -d "$storage_path" ]]; then
        # Count directories that look like Orthanc study storage
        find "$storage_path" -maxdepth 2 -type d 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

get_db_size() {
    local db_path="$1"
    if [[ -d "$db_path" ]]; then
        du -sh "$db_path" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

check_existing() {
    # Skip check if force flag is set
    if [[ "$FORCE_SETUP" == true ]]; then
        log_info "Force mode: stopping any existing containers..."
        docker compose down 2>/dev/null || true
        return 0
    fi
    
    local has_env=false
    local has_containers=false
    local has_dicom_data=false
    local has_db_data=false
    local existing_dicom_path=""
    local existing_db_path=""
    local dicom_size=""
    local db_size=""
    
    # Check for .env
    if [[ -f ".env" ]]; then
        has_env=true
        source .env 2>/dev/null || true
        existing_dicom_path="${DICOM_STORAGE:-}"
        existing_db_path="${POSTGRES_STORAGE:-}"
    fi
    
    # Check for running containers
    docker compose ps --quiet 2>/dev/null | grep -q . && has_containers=true
    
    # Check for existing data in configured paths
    if [[ -n "$existing_dicom_path" ]] && [[ -d "$existing_dicom_path" ]]; then
        dicom_size=$(du -sh "$existing_dicom_path" 2>/dev/null | cut -f1)
        [[ "$dicom_size" != "0" ]] && [[ "$dicom_size" != "4.0K" ]] && has_dicom_data=true
    fi
    
    if [[ -n "$existing_db_path" ]] && [[ -d "$existing_db_path" ]]; then
        db_size=$(du -sh "$existing_db_path" 2>/dev/null | cut -f1)
        [[ "$db_size" != "0" ]] && [[ "$db_size" != "4.0K" ]] && has_db_data=true
    fi
    
    # Also check default paths
    if [[ -d "$DEFAULT_DICOM_STORAGE" ]] && [[ -z "$existing_dicom_path" ]]; then
        existing_dicom_path="$DEFAULT_DICOM_STORAGE"
        dicom_size=$(du -sh "$DEFAULT_DICOM_STORAGE" 2>/dev/null | cut -f1)
        [[ "$dicom_size" != "0" ]] && [[ "$dicom_size" != "4.0K" ]] && has_dicom_data=true
    fi
    
    if [[ -d "$DEFAULT_POSTGRES_STORAGE" ]] && [[ -z "$existing_db_path" ]]; then
        existing_db_path="$DEFAULT_POSTGRES_STORAGE"
        db_size=$(du -sh "$DEFAULT_POSTGRES_STORAGE" 2>/dev/null | cut -f1)
        [[ "$db_size" != "0" ]] && [[ "$db_size" != "4.0K" ]] && has_db_data=true
    fi
    
    # Display findings
    if [[ "$has_env" == true ]] || [[ "$has_containers" == true ]] || [[ "$has_dicom_data" == true ]] || [[ "$has_db_data" == true ]]; then
        echo
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ⚠️  EXISTING INSTALLATION DETECTED                           ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo
        
        if [[ "$has_env" == true ]]; then
            echo -e "  ${CYAN}Found:${NC} .env configuration file"
            echo "         DICOM_STORAGE=${existing_dicom_path:-not set}"
            echo "         POSTGRES_STORAGE=${existing_db_path:-not set}"
            echo "         ORTHANC_AET=${ORTHANC_AET:-not set}"
        fi
        
        if [[ "$has_containers" == true ]]; then
            echo -e "  ${CYAN}Found:${NC} Running Docker containers"
            docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | head -5
        fi
        
        # Show existing data prominently
        if [[ "$has_dicom_data" == true ]] || [[ "$has_db_data" == true ]]; then
            echo
            echo -e "  ${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
            echo -e "  ${GREEN}║  📁  EXISTING DATA FOUND (will be preserved)              ║${NC}"
            echo -e "  ${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
            if [[ "$has_dicom_data" == true ]]; then
                echo -e "       DICOM files:    ${CYAN}$dicom_size${NC} in $existing_dicom_path"
            fi
            if [[ "$has_db_data" == true ]]; then
                echo -e "       Database:       ${CYAN}$db_size${NC} in $existing_db_path"
            fi
            echo
            echo -e "  ${GREEN}✓${NC}  Your studies and metadata will NOT be deleted."
            echo -e "  ${GREEN}✓${NC}  Setup will reconnect to existing data."
        fi
        
        echo
        
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log_info "Non-interactive mode: will update configuration (preserving data)"
            return 0
        fi
        
        echo "What would you like to do?"
        echo -e "  ${GREEN}1)${NC} Reinstall/Update (${GREEN}keeps all your studies${NC})"
        echo -e "  2) Keep existing configuration (just start services)"
        echo -e "  ${RED}3) Fresh install (WARNING: deletes all data!)${NC}"
        echo "  4) Cancel"
        echo
        read -p "Choice [1-4]: " choice
        
        case "$choice" in
            1)
                log_info "Will update configuration (preserving existing data)..."
                # Stop containers before updating
                if [[ "$has_containers" == true ]]; then
                    log_info "Stopping existing containers..."
                    docker compose down 2>/dev/null || true
                fi
                
                echo
                echo -e "${YELLOW}Do you want to change any settings?${NC}"
                echo "  1) Keep current settings (recommended)"
                echo "  2) Reconfigure everything"
                echo
                read -p "Choice [1-2]: " reconfig_choice
                
                if [[ "$reconfig_choice" == "2" ]]; then
                    # IMPORTANT: Save PostgreSQL password FIRST - database was initialized with it!
                    # Changing it would break the connection.
                    local saved_pg_password="$POSTGRES_PASSWORD"
                    
                    # Clear variables so collect_config prompts for new values
                    # But store old paths as defaults
                    DEFAULT_DICOM_STORAGE="${existing_dicom_path:-$DEFAULT_DICOM_STORAGE}"
                    DEFAULT_POSTGRES_STORAGE="${existing_db_path:-$DEFAULT_POSTGRES_STORAGE}"
                    DICOM_STORAGE=""
                    POSTGRES_STORAGE=""
                    ORTHANC_AET=""
                    ORTHANC_PASSWORD=""
                    
                    # Restore PostgreSQL password (can't change without recreating database)
                    POSTGRES_PASSWORD="$saved_pg_password"
                    if [[ -n "$POSTGRES_PASSWORD" ]]; then
                        log_info "Note: PostgreSQL password is preserved (required for existing database)"
                    fi
                else
                    # Keep existing values
                    DICOM_STORAGE="${existing_dicom_path:-$DEFAULT_DICOM_STORAGE}"
                    POSTGRES_STORAGE="${existing_db_path:-$DEFAULT_POSTGRES_STORAGE}"
                    ORTHANC_AET="${ORTHANC_AET:-$DEFAULT_ORTHANC_AET}"
                    ORTHANC_PASSWORD="${ORTHANC_PASSWORD:-$DEFAULT_ORTHANC_PASSWORD}"
                    USE_EXISTING=true
                fi
                return 0
                ;;
            2)
                log_info "Keeping existing configuration..."
                # Use existing values as defaults
                DICOM_STORAGE="${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
                POSTGRES_STORAGE="${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
                ORTHANC_AET="${ORTHANC_AET:-$DEFAULT_ORTHANC_AET}"
                ORTHANC_PASSWORD="${ORTHANC_PASSWORD:-$DEFAULT_ORTHANC_PASSWORD}"
                POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
                USE_EXISTING=true
                return 0
                ;;
            3)
                echo
                echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${YELLOW}║  🔄  FRESH INSTALL - What to do with existing data?          ║${NC}"
                echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
                echo
                if [[ "$has_dicom_data" == true ]]; then
                    echo -e "  DICOM files: ${CYAN}$dicom_size${NC} in $existing_dicom_path"
                fi
                if [[ "$has_db_data" == true ]]; then
                    echo -e "  Database:    ${CYAN}$db_size${NC} in $existing_db_path"
                fi
                echo
                echo -e "  ${GREEN}1)${NC} Archive data (backup to ./backups/, then start fresh)"
                echo -e "  ${RED}2)${NC} Delete data (permanently remove, then start fresh)"
                echo -e "  3) Cancel"
                echo
                read -p "Choice [1-3]: " data_choice
                
                case "$data_choice" in
                    1)
                        # Archive existing data
                        local timestamp=$(date +%Y%m%d_%H%M%S)
                        mkdir -p "$SCRIPT_DIR/backups"
                        
                        docker compose down 2>/dev/null || true
                        
                        if [[ "$has_dicom_data" == true && -n "$existing_dicom_path" ]]; then
                            log_info "Archiving DICOM data..."
                            local dicom_archive="$SCRIPT_DIR/backups/dicom_backup_${timestamp}.tar.gz"
                            if sudo tar -czf "$dicom_archive" -C "$(dirname "$existing_dicom_path")" "$(basename "$existing_dicom_path")" 2>/dev/null; then
                                log_success "Archived to: $dicom_archive"
                                sudo rm -rf "${existing_dicom_path:?}"/* 2>/dev/null
                            else
                                log_error "Failed to archive DICOM data"
                                exit 1
                            fi
                        fi
                        
                        if [[ "$has_db_data" == true && -n "$existing_db_path" ]]; then
                            log_info "Archiving PostgreSQL data..."
                            local db_archive="$SCRIPT_DIR/backups/postgres_backup_${timestamp}.tar.gz"
                            if sudo tar -czf "$db_archive" -C "$(dirname "$existing_db_path")" "$(basename "$existing_db_path")" 2>/dev/null; then
                                log_success "Archived to: $db_archive"
                                sudo rm -rf "${existing_db_path:?}"/* 2>/dev/null
                            else
                                log_error "Failed to archive PostgreSQL data"
                                exit 1
                            fi
                        fi
                        
                        rm -f .env 2>/dev/null
                        
                        # Clear all variables for fresh prompts
                        DICOM_STORAGE=""
                        POSTGRES_STORAGE=""
                        GRAFANA_STORAGE=""
                        ORTHANC_AET=""
                        ORTHANC_PASSWORD=""
                        POSTGRES_PASSWORD=""
                        USE_EXISTING=false
                        
                        log_success "Data archived! Proceeding with fresh install..."
                        echo
                        return 0
                        ;;
                    2)
                        echo
                        echo -e "${RED}⚠️  This will PERMANENTLY DELETE:${NC}"
                        [[ "$has_dicom_data" == true ]] && echo -e "     - $dicom_size of DICOM files"
                        [[ "$has_db_data" == true ]] && echo -e "     - $db_size of database"
                        echo
                        read -p "Type 'DELETE' to confirm: " confirm
                        if [[ "$confirm" == "DELETE" ]]; then
                            log_warn "Deleting all existing data..."
                            docker compose down -v 2>/dev/null || true
                            [[ -n "$existing_dicom_path" ]] && sudo rm -rf "$existing_dicom_path"/* 2>/dev/null
                            [[ -n "$existing_db_path" ]] && sudo rm -rf "$existing_db_path"/* 2>/dev/null
                            rm -f .env 2>/dev/null
                            
                            # Clear all variables for fresh prompts
                            DICOM_STORAGE=""
                            POSTGRES_STORAGE=""
                            GRAFANA_STORAGE=""
                            ORTHANC_AET=""
                            ORTHANC_PASSWORD=""
                            POSTGRES_PASSWORD=""
                            USE_EXISTING=false
                            
                            log_success "All data deleted. Proceeding with fresh install..."
                            return 0
                        else
                            log_info "Cancelled. Your data is safe."
                            exit 0
                        fi
                        ;;
                    *)
                        log_info "Cancelled."
                        exit 0
                        ;;
                esac
                ;;
            4|*)
                echo "Setup cancelled."
                exit 0
                ;;
        esac
    fi
    
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────────
# MAIN SETUP
# ─────────────────────────────────────────────────────────────────────────────────

collect_config() {
    # If using existing config, skip collection
    if [[ "$USE_EXISTING" == true ]]; then
        return
    fi
    
    if [[ "$USE_DEFAULTS" == true ]]; then
        DICOM_STORAGE="${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
        POSTGRES_STORAGE="${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
        GRAFANA_STORAGE="${GRAFANA_STORAGE:-$DEFAULT_GRAFANA_STORAGE}"
        ORTHANC_AET="${ORTHANC_AET:-$DEFAULT_ORTHANC_AET}"
        DICOM_PORT="${DICOM_PORT:-$DEFAULT_DICOM_PORT}"
        OPERATOR_UI_PORT="${OPERATOR_UI_PORT:-$DEFAULT_OPERATOR_UI_PORT}"
        ORTHANC_WEB_PORT="${ORTHANC_WEB_PORT:-$DEFAULT_ORTHANC_WEB_PORT}"
        OHIF_PORT="${OHIF_PORT:-$DEFAULT_OHIF_PORT}"
        POSTGRES_PORT="${POSTGRES_PORT:-$DEFAULT_POSTGRES_PORT}"
        ROUTING_API_PORT="${ROUTING_API_PORT:-$DEFAULT_ROUTING_API_PORT}"
        GRAFANA_PORT="${GRAFANA_PORT:-$DEFAULT_GRAFANA_PORT}"
        ORTHANC_USERNAME="${ORTHANC_USERNAME:-$DEFAULT_ORTHANC_USERNAME}"
        ORTHANC_PASSWORD="${ORTHANC_PASSWORD:-$DEFAULT_ORTHANC_PASSWORD}"
        POSTGRES_USER="${POSTGRES_USER:-$DEFAULT_POSTGRES_USER}"
        POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_password)}"
        GRAFANA_USER="${GRAFANA_USER:-$DEFAULT_GRAFANA_USER}"
        GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-$DEFAULT_GRAFANA_PASSWORD}"
        TZ="${TZ:-$DEFAULT_TZ}"
        # Mercure integration (optional)
        MERCURE_DB_HOST="${MERCURE_DB_HOST:-$DEFAULT_MERCURE_DB_HOST}"
        MERCURE_DB_PORT="${MERCURE_DB_PORT:-$DEFAULT_MERCURE_DB_PORT}"
        MERCURE_DB_NAME="${MERCURE_DB_NAME:-$DEFAULT_MERCURE_DB_NAME}"
        MERCURE_DB_USER="${MERCURE_DB_USER:-$DEFAULT_MERCURE_DB_USER}"
        MERCURE_DB_PASS="${MERCURE_DB_PASS:-$DEFAULT_MERCURE_DB_PASS}"
        return
    fi
    
    # ═══════════════════════════════════════════════════════════════════════════
    # SECTION 1: STORAGE PATHS (Essential)
    # ═══════════════════════════════════════════════════════════════════════════
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  1/5  STORAGE PATHS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    # DICOM Storage
    if [[ -z "$DICOM_STORAGE" ]]; then
        echo -e "${YELLOW}Where should DICOM files be stored?${NC}"
        echo "  This can be a local path or network mount (e.g., /mnt/nas/orthanc)"
        prompt "DICOM storage path" "$DEFAULT_DICOM_STORAGE" DICOM_STORAGE
    fi
    
    # PostgreSQL Storage
    if [[ -z "$POSTGRES_STORAGE" ]]; then
        echo
        echo -e "${YELLOW}Where should PostgreSQL data be stored?${NC}"
        echo "  Recommended: local SSD for best performance"
        prompt "PostgreSQL data path" "$DEFAULT_POSTGRES_STORAGE" POSTGRES_STORAGE
    fi
    
    # Grafana Storage
    if [[ -z "$GRAFANA_STORAGE" ]]; then
        echo
        echo -e "${YELLOW}Where should Grafana data be stored?${NC}"
        prompt "Grafana data path" "$DEFAULT_GRAFANA_STORAGE" GRAFANA_STORAGE
    fi
    
    # ═══════════════════════════════════════════════════════════════════════════
    # SECTION 2: DICOM SETTINGS
    # ═══════════════════════════════════════════════════════════════════════════
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  2/5  DICOM SETTINGS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    # AE Title
    if [[ -z "$ORTHANC_AET" ]]; then
        echo -e "${YELLOW}DICOM AE Title (Application Entity Title)${NC}"
        echo "  This is how your PACS identifies itself to other DICOM devices"
        prompt "AE Title" "$DEFAULT_ORTHANC_AET" ORTHANC_AET
    fi
    
    # DICOM Port
    if [[ -z "$DICOM_PORT" ]]; then
        echo
        echo -e "${YELLOW}DICOM network port${NC}"
        echo "  Standard is 4242, but change if you have conflicts"
        prompt "DICOM port" "$DEFAULT_DICOM_PORT" DICOM_PORT
    fi
    
    # ═══════════════════════════════════════════════════════════════════════════
    # SECTION 3: CREDENTIALS
    # ═══════════════════════════════════════════════════════════════════════════
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  3/5  CREDENTIALS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    # Orthanc Username
    if [[ -z "$ORTHANC_USERNAME" ]]; then
        echo -e "${YELLOW}Orthanc admin username${NC}"
        prompt "Username" "$DEFAULT_ORTHANC_USERNAME" ORTHANC_USERNAME
    fi
    
    # Orthanc Password
    if [[ -z "$ORTHANC_PASSWORD" ]]; then
        echo
        prompt_password "Orthanc admin password" ORTHANC_PASSWORD "$DEFAULT_ORTHANC_PASSWORD"
    fi
    
    # PostgreSQL User
    if [[ -z "$POSTGRES_USER" ]]; then
        echo
        echo -e "${YELLOW}PostgreSQL database user${NC}"
        prompt "DB username" "$DEFAULT_POSTGRES_USER" POSTGRES_USER
    fi
    
    # PostgreSQL Password
    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        echo
        prompt_password "PostgreSQL password (auto-generate if blank)" POSTGRES_PASSWORD ""
    else
        echo
        echo -e "  PostgreSQL password: ${GREEN}[preserved from existing database]${NC}"
    fi
    
    # Grafana credentials
    if [[ -z "$GRAFANA_USER" ]]; then
        echo
        echo -e "${YELLOW}Grafana admin username${NC}"
        prompt "Grafana username" "$DEFAULT_GRAFANA_USER" GRAFANA_USER
    fi
    
    if [[ -z "$GRAFANA_PASSWORD" ]]; then
        echo
        echo -e "${YELLOW}Grafana admin password${NC}"
        prompt "Grafana password" "$DEFAULT_GRAFANA_PASSWORD" GRAFANA_PASSWORD
    fi
    
    # ═══════════════════════════════════════════════════════════════════════════
    # SECTION 4: ADVANCED (Web Ports & Timezone)
    # ═══════════════════════════════════════════════════════════════════════════
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  4/5  ADVANCED SETTINGS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  Current web port assignments (sequential from 8040):"
    echo -e "    Dashboard:    ${CYAN}${OPERATOR_UI_PORT:-$DEFAULT_OPERATOR_UI_PORT}${NC}"
    echo -e "    Orthanc Web:  ${CYAN}${ORTHANC_WEB_PORT:-$DEFAULT_ORTHANC_WEB_PORT}${NC}"
    echo -e "    OHIF Viewer:  ${CYAN}${OHIF_PORT:-$DEFAULT_OHIF_PORT}${NC}"
    echo -e "    PostgreSQL:   ${CYAN}${POSTGRES_PORT:-$DEFAULT_POSTGRES_PORT}${NC}"
    echo -e "    Routing API:  ${CYAN}${ROUTING_API_PORT:-$DEFAULT_ROUTING_API_PORT}${NC}"
    echo -e "    Grafana:      ${CYAN}${GRAFANA_PORT:-$DEFAULT_GRAFANA_PORT}${NC}"
    echo
    read -p "Change web ports? [y/N]: " change_ports
    
    if [[ "$change_ports" =~ ^[Yy] ]]; then
        echo
        echo -e "${YELLOW}Enter new base port (others will be sequential):${NC}"
        read -p "Base port [${DEFAULT_OPERATOR_UI_PORT}]: " base_port
        base_port="${base_port:-$DEFAULT_OPERATOR_UI_PORT}"
        
        OPERATOR_UI_PORT=$base_port
        ORTHANC_WEB_PORT=$((base_port + 1))
        OHIF_PORT=$((base_port + 2))
        POSTGRES_PORT=$((base_port + 3))
        ROUTING_API_PORT=$((base_port + 4))
        GRAFANA_PORT=$((base_port + 5))
        
        echo -e "  New assignments:"
        echo -e "    Dashboard:    ${GREEN}$OPERATOR_UI_PORT${NC}"
        echo -e "    Orthanc Web:  ${GREEN}$ORTHANC_WEB_PORT${NC}"
        echo -e "    OHIF Viewer:  ${GREEN}$OHIF_PORT${NC}"
        echo -e "    PostgreSQL:   ${GREEN}$POSTGRES_PORT${NC}"
        echo -e "    Routing API:  ${GREEN}$ROUTING_API_PORT${NC}"
        echo -e "    Grafana:      ${GREEN}$GRAFANA_PORT${NC}"
    else
        OPERATOR_UI_PORT="${OPERATOR_UI_PORT:-$DEFAULT_OPERATOR_UI_PORT}"
        ORTHANC_WEB_PORT="${ORTHANC_WEB_PORT:-$DEFAULT_ORTHANC_WEB_PORT}"
        OHIF_PORT="${OHIF_PORT:-$DEFAULT_OHIF_PORT}"
        POSTGRES_PORT="${POSTGRES_PORT:-$DEFAULT_POSTGRES_PORT}"
        ROUTING_API_PORT="${ROUTING_API_PORT:-$DEFAULT_ROUTING_API_PORT}"
        GRAFANA_PORT="${GRAFANA_PORT:-$DEFAULT_GRAFANA_PORT}"
    fi
    
    # Timezone
    echo
    echo -e "  Current timezone: ${CYAN}${TZ:-$DEFAULT_TZ}${NC}"
    read -p "Change timezone? [y/N]: " change_tz
    
    if [[ "$change_tz" =~ ^[Yy] ]]; then
        echo -e "${YELLOW}Enter timezone (e.g., America/New_York, Europe/London):${NC}"
        prompt "Timezone" "$DEFAULT_TZ" TZ
    else
        TZ="${TZ:-$DEFAULT_TZ}"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════════
    # SECTION 5: MERCURE AI INTEGRATION (Optional)
    # ═══════════════════════════════════════════════════════════════════════════
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  5/5  MERCURE AI INTEGRATION (Optional)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${YELLOW}Mercure is an AI orchestration platform.${NC}"
    echo -e "  If Mercure is running on this system, you can enable enhanced"
    echo -e "  tracking by providing its database credentials."
    echo
    echo -e "  Mercure DB password is typically found in:"
    echo -e "    ${CYAN}/opt/mercure/config/db.env${NC}"
    echo
    
    if [[ -n "$DEFAULT_MERCURE_DB_PASS" ]]; then
        echo -e "  Current status: ${GREEN}Configured${NC}"
        echo -e "    Host: ${CYAN}${MERCURE_DB_HOST:-$DEFAULT_MERCURE_DB_HOST}${NC}"
    else
        echo -e "  Current status: ${YELLOW}Not configured${NC}"
    fi
    echo
    
    read -p "Configure Mercure integration? [y/N]: " configure_mercure
    
    if [[ "$configure_mercure" =~ ^[Yy] ]]; then
        echo
        echo -e "${YELLOW}Mercure PostgreSQL connection settings:${NC}"
        prompt "Mercure DB host" "$DEFAULT_MERCURE_DB_HOST" MERCURE_DB_HOST
        prompt "Mercure DB port" "$DEFAULT_MERCURE_DB_PORT" MERCURE_DB_PORT
        prompt "Mercure DB name" "$DEFAULT_MERCURE_DB_NAME" MERCURE_DB_NAME
        prompt "Mercure DB user" "$DEFAULT_MERCURE_DB_USER" MERCURE_DB_USER
        echo
        echo -e "${YELLOW}Mercure DB password:${NC}"
        echo "  (Leave blank to skip Mercure integration)"
        prompt_password "Mercure DB password" MERCURE_DB_PASS "$DEFAULT_MERCURE_DB_PASS"
    else
        MERCURE_DB_HOST="${MERCURE_DB_HOST:-$DEFAULT_MERCURE_DB_HOST}"
        MERCURE_DB_PORT="${MERCURE_DB_PORT:-$DEFAULT_MERCURE_DB_PORT}"
        MERCURE_DB_NAME="${MERCURE_DB_NAME:-$DEFAULT_MERCURE_DB_NAME}"
        MERCURE_DB_USER="${MERCURE_DB_USER:-$DEFAULT_MERCURE_DB_USER}"
        MERCURE_DB_PASS="${MERCURE_DB_PASS:-$DEFAULT_MERCURE_DB_PASS}"
    fi
}

show_summary() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CONFIGURATION SUMMARY${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${CYAN}Storage Paths${NC}"
    echo "    DICOM:      ${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
    echo "    PostgreSQL: ${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
    echo "    Grafana:    ${GRAFANA_STORAGE:-$DEFAULT_GRAFANA_STORAGE}"
    echo
    echo -e "  ${CYAN}DICOM Settings${NC}"
    echo "    AE Title:   ${ORTHANC_AET:-$DEFAULT_ORTHANC_AET}"
    echo "    Port:       ${DICOM_PORT:-$DEFAULT_DICOM_PORT}"
    echo
    echo -e "  ${CYAN}Web Ports${NC}"
    echo "    Dashboard:    ${OPERATOR_UI_PORT:-$DEFAULT_OPERATOR_UI_PORT}"
    echo "    Orthanc Web:  ${ORTHANC_WEB_PORT:-$DEFAULT_ORTHANC_WEB_PORT}"
    echo "    OHIF Viewer:  ${OHIF_PORT:-$DEFAULT_OHIF_PORT}"
    echo "    PostgreSQL:   ${POSTGRES_PORT:-$DEFAULT_POSTGRES_PORT}"
    echo "    Routing API:  ${ROUTING_API_PORT:-$DEFAULT_ROUTING_API_PORT}"
    echo "    Grafana:      ${GRAFANA_PORT:-$DEFAULT_GRAFANA_PORT}"
    echo
    echo -e "  ${CYAN}Credentials${NC}"
    echo "    Orthanc:    ${ORTHANC_USERNAME:-$DEFAULT_ORTHANC_USERNAME} / ${ORTHANC_PASSWORD:-$DEFAULT_ORTHANC_PASSWORD}"
    echo "    PostgreSQL: ${POSTGRES_USER:-$DEFAULT_POSTGRES_USER} / ${POSTGRES_PASSWORD:-[auto-generated]}"
    echo "    Grafana:    ${GRAFANA_USER:-$DEFAULT_GRAFANA_USER} / ${GRAFANA_PASSWORD:-$DEFAULT_GRAFANA_PASSWORD}"
    echo
    echo -e "  ${CYAN}Other${NC}"
    echo "    Timezone:   ${TZ:-$DEFAULT_TZ}"
    echo
    echo -e "  ${CYAN}Mercure AI Integration${NC}"
    if [[ -n "${MERCURE_DB_PASS:-$DEFAULT_MERCURE_DB_PASS}" ]]; then
        echo "    Status:     ${GREEN}Enabled${NC}"
        echo "    Host:       ${MERCURE_DB_HOST:-$DEFAULT_MERCURE_DB_HOST}"
        echo "    Database:   ${MERCURE_DB_NAME:-$DEFAULT_MERCURE_DB_NAME}"
    else
        echo "    Status:     ${YELLOW}Not configured${NC}"
    fi
    echo
}

create_env_file() {
    log_info "Creating .env file..."
    
    # Use configured values or defaults
    local env_dicom="${DICOM_STORAGE:-$DEFAULT_DICOM_STORAGE}"
    local env_postgres="${POSTGRES_STORAGE:-$DEFAULT_POSTGRES_STORAGE}"
    local env_grafana="${GRAFANA_STORAGE:-$DEFAULT_GRAFANA_STORAGE}"
    local env_aet="${ORTHANC_AET:-$DEFAULT_ORTHANC_AET}"
    local env_orthanc_pass="${ORTHANC_PASSWORD:-$DEFAULT_ORTHANC_PASSWORD}"
    local env_pg_pass="${POSTGRES_PASSWORD:-$DEFAULT_POSTGRES_PASSWORD}"
    local env_tz="${TZ:-$DEFAULT_TZ}"
    
    # Generate PostgreSQL password if not set
    if [[ -z "$env_pg_pass" ]]; then
        env_pg_pass=$(generate_password)
        log_info "Generated PostgreSQL password"
    fi
    
    cat > .env << EOF
# ═══════════════════════════════════════════════════════════════════════════════
# ORTHANC PACS CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════
# Generated by setup.sh on $(date)
# 
# For all available options, see: config/env.defaults
# ═══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────────
# STORAGE PATHS
# ─────────────────────────────────────────────────────────────────────────────────
DICOM_STORAGE=$env_dicom
POSTGRES_STORAGE=$env_postgres
GRAFANA_STORAGE=$env_grafana

# ─────────────────────────────────────────────────────────────────────────────────
# DICOM SETTINGS
# ─────────────────────────────────────────────────────────────────────────────────
ORTHANC_AET=$env_aet
DICOM_PORT=${DICOM_PORT:-$DEFAULT_DICOM_PORT}

# ─────────────────────────────────────────────────────────────────────────────────
# WEB PORTS
# ─────────────────────────────────────────────────────────────────────────────────
OPERATOR_UI_PORT=${OPERATOR_UI_PORT:-$DEFAULT_OPERATOR_UI_PORT}
ORTHANC_WEB_PORT=${ORTHANC_WEB_PORT:-$DEFAULT_ORTHANC_WEB_PORT}
OHIF_PORT=${OHIF_PORT:-$DEFAULT_OHIF_PORT}
POSTGRES_PORT=${POSTGRES_PORT:-$DEFAULT_POSTGRES_PORT}
ROUTING_API_PORT=${ROUTING_API_PORT:-$DEFAULT_ROUTING_API_PORT}
GRAFANA_PORT=${GRAFANA_PORT:-$DEFAULT_GRAFANA_PORT}

# ─────────────────────────────────────────────────────────────────────────────────
# ORTHANC CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────────
ORTHANC_USERNAME=${ORTHANC_USERNAME:-$DEFAULT_ORTHANC_USERNAME}
ORTHANC_PASSWORD=$env_orthanc_pass

# ─────────────────────────────────────────────────────────────────────────────────
# POSTGRESQL CREDENTIALS
# ⚠️  WARNING: Do not change POSTGRES_PASSWORD after initial setup!
# ─────────────────────────────────────────────────────────────────────────────────
POSTGRES_USER=${POSTGRES_USER:-$DEFAULT_POSTGRES_USER}
POSTGRES_PASSWORD=$env_pg_pass

# ─────────────────────────────────────────────────────────────────────────────────
# GRAFANA CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────────
GRAFANA_USER=${GRAFANA_USER:-$DEFAULT_GRAFANA_USER}
GRAFANA_PASSWORD=${GRAFANA_PASSWORD:-$DEFAULT_GRAFANA_PASSWORD}

# ─────────────────────────────────────────────────────────────────────────────────
# TIMEZONE
# ─────────────────────────────────────────────────────────────────────────────────
TZ=$env_tz

# ─────────────────────────────────────────────────────────────────────────────────
# DICOM MODALITIES
# ─────────────────────────────────────────────────────────────────────────────────
# Format: MODALITY_<NAME>=<AET>|<HOST>|<PORT>
# Modify these to match your network configuration.
# Run 'make seed-modalities' after changes.

EOF

    # Append modality definitions from defaults or existing env
    local modalities_added=0
    
    # First check if we have existing modalities in environment
    while IFS='=' read -r var_name var_value; do
        echo "$var_name=$var_value" >> .env
        modalities_added=$((modalities_added + 1))
    done < <(env | grep "^MODALITY_" | sort)
    
    # If no modalities found, copy from defaults
    if [[ $modalities_added -eq 0 && -f "$SCRIPT_DIR/config/env.defaults" ]]; then
        grep "^MODALITY_" "$SCRIPT_DIR/config/env.defaults" >> .env 2>/dev/null || true
    fi
    
    # Append Mercure integration settings
    cat >> .env << EOF

# ─────────────────────────────────────────────────────────────────────────────────
# MERCURE AI INTEGRATION (Optional)
# ─────────────────────────────────────────────────────────────────────────────────
# Enable enhanced AI processing tracking by connecting to Mercure's database.
# The password is found in: /opt/mercure/config/db.env

MERCURE_DB_HOST=${MERCURE_DB_HOST:-$DEFAULT_MERCURE_DB_HOST}
MERCURE_DB_PORT=${MERCURE_DB_PORT:-$DEFAULT_MERCURE_DB_PORT}
MERCURE_DB_NAME=${MERCURE_DB_NAME:-$DEFAULT_MERCURE_DB_NAME}
MERCURE_DB_USER=${MERCURE_DB_USER:-$DEFAULT_MERCURE_DB_USER}
MERCURE_DB_PASS=${MERCURE_DB_PASS:-$DEFAULT_MERCURE_DB_PASS}
EOF

    chmod 640 .env
    
    # If running as sudo, change ownership to the original user
    if [[ -n "$SUDO_USER" ]]; then
        chown "$SUDO_USER:$SUDO_USER" .env
    fi
    
    log_success ".env file created"
    
    # Store the generated password for display
    POSTGRES_PASSWORD="$env_pg_pass"
    ORTHANC_PASSWORD="$env_orthanc_pass"
}

update_orthanc_json() {
    log_info "Updating config/orthanc.json..."
    
    # Update PostgreSQL password in orthanc.json
    sed -i "s/\"Password\" : \"[^\"]*\"/\"Password\" : \"$POSTGRES_PASSWORD\"/" config/orthanc.json
    
    # Update AE Title
    sed -i "s/\"DicomAet\" : \"[^\"]*\"/\"DicomAet\" : \"$ORTHANC_AET\"/" config/orthanc.json
    
    # Update Orthanc password
    sed -i "s/\"orthanc_admin\": \"[^\"]*\"/\"orthanc_admin\": \"$ORTHANC_PASSWORD\"/" config/orthanc.json
    
    log_success "config/orthanc.json updated"
}

# ─────────────────────────────────────────────────────────────────────────────────
# Handle existing data in a storage directory
# Returns: 0 = proceed, 1 = abort
# ─────────────────────────────────────────────────────────────────────────────────
handle_existing_data() {
    local dir_path="$1"
    local dir_name="$2"  # Human-readable name (e.g., "DICOM Storage", "PostgreSQL")
    
    # Check if directory exists and has content
    if [[ ! -d "$dir_path" ]]; then
        return 0  # Directory doesn't exist, safe to create
    fi
    
    # Check if directory has any content
    local file_count=$(find "$dir_path" -mindepth 1 2>/dev/null | head -100 | wc -l)
    if [[ $file_count -eq 0 ]]; then
        return 0  # Directory exists but is empty
    fi
    
    # Directory has content - get size
    local dir_size=$(sudo du -sh "$dir_path" 2>/dev/null | cut -f1)
    
    echo
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ⚠️  EXISTING DATA DETECTED${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${CYAN}Location:${NC} $dir_path"
    echo -e "  ${CYAN}Type:${NC}     $dir_name"
    echo -e "  ${CYAN}Size:${NC}     $dir_size"
    echo -e "  ${CYAN}Files:${NC}    ~$file_count+ items"
    echo
    echo -e "  What would you like to do with this data?"
    echo
    echo -e "    ${GREEN}1)${NC} Keep it (use existing data, if compatible)"
    echo -e "    ${YELLOW}2)${NC} Archive it (move to backup, start fresh)"
    echo -e "    ${RED}3)${NC} Delete it (permanently remove, start fresh)"
    echo -e "    ${BLUE}4)${NC} Abort (cancel setup)"
    echo
    
    while true; do
        read -p "  Enter choice [1-4]: " choice
        case "$choice" in
            1)
                log_info "Keeping existing data in $dir_path"
                return 0
                ;;
            2)
                # Archive to backup directory
                local timestamp=$(date +%Y%m%d_%H%M%S)
                local backup_dir="$SCRIPT_DIR/backups"
                local archive_name="${dir_name// /_}_${timestamp}.tar.gz"
                
                mkdir -p "$backup_dir"
                
                log_info "Archiving $dir_path to $backup_dir/$archive_name..."
                if sudo tar -czf "$backup_dir/$archive_name" -C "$(dirname "$dir_path")" "$(basename "$dir_path")" 2>/dev/null; then
                    log_success "Archived to: $backup_dir/$archive_name"
                    
                    # Clear the directory (but keep it)
                    log_info "Clearing $dir_path..."
                    sudo rm -rf "${dir_path:?}"/* 2>/dev/null || true
                    log_success "Directory cleared"
                else
                    log_error "Failed to create archive"
                    return 1
                fi
                return 0
                ;;
            3)
                echo
                echo -e "  ${RED}⚠️  WARNING: This will permanently delete all data in:${NC}"
                echo -e "     $dir_path ($dir_size)"
                echo
                read -p "  Type 'DELETE' to confirm: " confirm
                if [[ "$confirm" == "DELETE" ]]; then
                    log_info "Deleting contents of $dir_path..."
                    sudo rm -rf "${dir_path:?}"/* 2>/dev/null || true
                    log_success "Directory cleared"
                    return 0
                else
                    log_warn "Deletion cancelled"
                    return 1
                fi
                ;;
            4)
                log_info "Setup aborted by user"
                return 1
                ;;
            *)
                echo -e "  ${RED}Invalid choice. Please enter 1, 2, 3, or 4.${NC}"
                ;;
        esac
    done
}

create_directories() {
    log_info "Creating storage directories..."
    
    # Handle DICOM storage
    if [[ -d "$DICOM_STORAGE" ]]; then
        if ! handle_existing_data "$DICOM_STORAGE" "DICOM_Storage"; then
            log_error "Setup aborted due to existing DICOM data"
            exit 1
        fi
    fi
    
    # Create DICOM storage if needed
    if [[ ! -d "$DICOM_STORAGE" ]]; then
        if sudo mkdir -p "$DICOM_STORAGE" 2>/dev/null || mkdir -p "$DICOM_STORAGE" 2>/dev/null; then
            log_success "Created: $DICOM_STORAGE"
        else
            log_error "Failed to create: $DICOM_STORAGE"
            log_warn "You may need to create it manually with: sudo mkdir -p $DICOM_STORAGE"
        fi
    else
        log_success "Ready: $DICOM_STORAGE"
    fi
    
    # Set DICOM permissions (Orthanc runs as UID 1000)
    sudo chown -R 1000:1000 "$DICOM_STORAGE" 2>/dev/null || \
        chown -R 1000:1000 "$DICOM_STORAGE" 2>/dev/null || \
        log_warn "Could not set ownership on $DICOM_STORAGE"
    
    # Handle PostgreSQL storage
    if [[ -d "$POSTGRES_STORAGE" ]]; then
        if ! handle_existing_data "$POSTGRES_STORAGE" "PostgreSQL_Data"; then
            log_error "Setup aborted due to existing PostgreSQL data"
            exit 1
        fi
    fi
    
    # Create PostgreSQL storage if needed
    if [[ ! -d "$POSTGRES_STORAGE" ]]; then
        if sudo mkdir -p "$POSTGRES_STORAGE" 2>/dev/null || mkdir -p "$POSTGRES_STORAGE" 2>/dev/null; then
            log_success "Created: $POSTGRES_STORAGE"
        else
            log_error "Failed to create: $POSTGRES_STORAGE"
            log_warn "You may need to create it manually with: sudo mkdir -p $POSTGRES_STORAGE"
        fi
    else
        log_success "Ready: $POSTGRES_STORAGE"
    fi
    
    # Set PostgreSQL permissions (postgres runs as UID 999)
    sudo chown -R 999:999 "$POSTGRES_STORAGE" 2>/dev/null || \
        chown -R 999:999 "$POSTGRES_STORAGE" 2>/dev/null || \
        log_warn "Could not set ownership on $POSTGRES_STORAGE"
    
    # Handle Grafana storage if configured
    if [[ -n "${GRAFANA_STORAGE:-}" && -d "$GRAFANA_STORAGE" ]]; then
        if ! handle_existing_data "$GRAFANA_STORAGE" "Grafana_Data"; then
            log_error "Setup aborted due to existing Grafana data"
            exit 1
        fi
    fi
    
    # Create Grafana storage if configured
    if [[ -n "${GRAFANA_STORAGE:-}" ]]; then
        if [[ ! -d "$GRAFANA_STORAGE" ]]; then
            if sudo mkdir -p "$GRAFANA_STORAGE" 2>/dev/null || mkdir -p "$GRAFANA_STORAGE" 2>/dev/null; then
                log_success "Created: $GRAFANA_STORAGE"
            else
                log_warn "Could not create Grafana storage: $GRAFANA_STORAGE"
            fi
        fi
        # Set Grafana permissions (runs as UID 472)
        sudo chown -R 472:472 "$GRAFANA_STORAGE" 2>/dev/null || \
            chown -R 472:472 "$GRAFANA_STORAGE" 2>/dev/null || \
            log_warn "Could not set ownership on $GRAFANA_STORAGE"
    fi
    
    # Grafana provisioning directories (in repo, not data)
    log_info "Setting up Grafana configuration..."
    mkdir -p "$SCRIPT_DIR/grafana/provisioning/datasources" 2>/dev/null || true
    mkdir -p "$SCRIPT_DIR/grafana/provisioning/dashboards" 2>/dev/null || true
    mkdir -p "$SCRIPT_DIR/grafana/dashboards" 2>/dev/null || true
    log_success "Grafana directories ready"
}

make_executable() {
    chmod +x orthanc 2>/dev/null || true
    chmod +x setup.sh 2>/dev/null || true
}

start_services() {
    log_info "Building and starting Docker services..."
    docker compose build --quiet
    docker compose up -d
    
    log_info "Waiting for Orthanc to be healthy..."
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -u "orthanc_admin:$ORTHANC_PASSWORD" "http://localhost:8041/system" &>/dev/null; then
            log_success "Orthanc is healthy"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    
    echo
    log_warn "Orthanc may still be starting. Check with: docker compose ps"
    return 1
}

seed_modalities() {
    log_info "Configuring DICOM modalities from .env..."
    
    local port="${ORTHANC_WEB_PORT:-8041}"
    local orthanc_url="http://localhost:$port"
    local user="${ORTHANC_USERNAME:-orthanc_admin}"
    local pass="${ORTHANC_PASSWORD:-helloaide123}"
    local auth="$user:$pass"
    
    log_info "Connecting to Orthanc at $orthanc_url..."
    
    # Check current modalities
    local existing=$(curl -s -u "$auth" "$orthanc_url/modalities" 2>/dev/null)
    log_info "Current modalities: $existing"
    
    # Read modalities from environment variables (MODALITY_*)
    # Format: MODALITY_<NAME>=<AET>|<HOST>|<PORT>
    local modality_count=0
    
    # Read modalities directly from .env file (more reliable than env vars)
    local modality_file=""
    
    # Check if we can read .env
    if [[ -f ".env" ]]; then
        if [[ -r ".env" ]]; then
            if grep -q "^MODALITY_" .env 2>/dev/null; then
                modality_file=".env"
            fi
        else
            log_warn "Cannot read .env (permission denied). Try: sudo chown \$USER:\$USER .env"
        fi
    fi
    
    # Fallback to defaults
    if [[ -z "$modality_file" && -f "$SCRIPT_DIR/config/env.defaults" ]]; then
        modality_file="$SCRIPT_DIR/config/env.defaults"
        log_info "Using default modalities from config/env.defaults"
    fi
    
    if [[ -z "$modality_file" ]]; then
        log_warn "No modality configuration found in .env or config/env.defaults"
        return 1
    fi
    
    log_info "Reading modalities from $modality_file"
    
    # Find all MODALITY_* lines in the file
    while IFS='=' read -r var_name var_value; do
        # Extract modality name from variable (MODALITY_MERCURE -> MERCURE)
        local name="${var_name#MODALITY_}"
        
        # Skip empty values
        [[ -z "$var_value" ]] && continue
        
        # Parse the value: AET|HOST|PORT
        IFS='|' read -r aet host port <<< "$var_value"
        
        # Validate
        if [[ -z "$aet" || -z "$host" || -z "$port" ]]; then
            log_warn "Invalid modality format for $name: $var_value (expected AET|HOST|PORT)"
            continue
        fi
        
        # Check if this modality already exists with same config
        if echo "$existing" | grep -q "\"$name\""; then
            log_info "Modality $name already exists, updating..."
        fi
        
        local config="{\"AET\":\"$aet\",\"Host\":\"$host\",\"Port\":$port,\"AllowEcho\":true,\"AllowStore\":true}"
        
        if curl -s -u "$auth" -X PUT "$orthanc_url/modalities/$name" \
            -H "Content-Type: application/json" \
            -d "$config" &>/dev/null; then
            log_success "Configured modality: $name ($aet @ $host:$port)"
            modality_count=$((modality_count + 1))
        else
            log_warn "Failed to configure modality: $name"
        fi
    done < <(grep "^MODALITY_" "$modality_file" | sort)
    
    if [[ $modality_count -eq 0 ]]; then
        log_warn "No modalities configured. Add MODALITY_* variables to .env"
        log_info "Example: MODALITY_WORKSTATION=WORKSTATION1|192.168.1.100|4242"
    else
        log_success "Configured $modality_count modalities"
    fi
}

print_completion() {
    echo
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}║   ✅  SETUP COMPLETE - SERVICES RUNNING                       ║${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${CYAN}Access your Orthanc installation:${NC}"
    echo
    echo -e "  📊 Dashboard:    ${YELLOW}http://localhost:8040${NC}"
    echo -e "  🏥 Orthanc UI:   ${YELLOW}http://localhost:8041${NC}"
    echo -e "  🖼️  OHIF Viewer:  ${YELLOW}http://localhost:8042${NC}"
    echo -e "  📈 Grafana QI:   ${YELLOW}http://localhost:8045${NC}"
    echo -e "  📡 DICOM Port:   ${YELLOW}$ORTHANC_AET @ port 4242${NC}"
    echo
    echo -e "${CYAN}CLI commands:${NC}"
    echo -e "  ${YELLOW}./orthanc status${NC}       - Check system status"
    echo -e "  ${YELLOW}./orthanc studies${NC}      - List recent studies"
    echo -e "  ${YELLOW}./orthanc destinations${NC} - List DICOM destinations"
    echo
    echo -e "${CYAN}Credentials (saved in .env):${NC}"
    echo "  Orthanc:    orthanc_admin / $ORTHANC_PASSWORD"
    echo "  PostgreSQL: orthanc / $POSTGRES_PASSWORD"
    echo "  Grafana:    admin / admin (change after first login)"
    echo
}

# ─────────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────────

main() {
    # Store env vars before parsing (so --args can override)
    DICOM_STORAGE_ENV="${DICOM_STORAGE:-}"
    POSTGRES_STORAGE_ENV="${POSTGRES_STORAGE:-}"
    ORTHANC_AET_ENV="${ORTHANC_AET:-}"
    ORTHANC_PASSWORD_ENV="${ORTHANC_PASSWORD:-}"
    POSTGRES_PASSWORD_ENV="${POSTGRES_PASSWORD:-}"
    
    # If no arguments, show interactive menu
    if [[ $# -eq 0 ]]; then
        show_interactive_menu
        exit 0
    fi
    
    parse_args "$@"
    
    # Handle --menu flag
    if [[ "$INTERACTIVE_MENU" == true ]]; then
        show_interactive_menu
        exit 0
    fi
    
    # Handle --setup flag (interactive setup without full menu)
    if [[ "$DO_SETUP" == true ]]; then
        print_banner
        check_existing
        collect_config
        show_summary
        
        echo
        read -p "Proceed with setup? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
            echo "Setup cancelled."
            exit 0
        fi
        
        echo
        create_env_file
        update_orthanc_json
        create_directories
        make_executable
        start_services
        if [[ $? -eq 0 ]]; then
            seed_modalities
        fi
        print_completion
        exit 0
    fi
    
    # Handle backup/restore operations first
    if [[ "$DO_BACKUP" == true ]]; then
        do_backup
        exit 0
    fi
    
    if [[ "$DO_RESTORE" == true ]]; then
        do_restore
        exit 0
    fi
    
    # Normal setup flow (when args provided)
    print_banner
    check_existing
    collect_config
    show_summary
    
    if [[ "$NON_INTERACTIVE" != true ]]; then
        echo
        read -p "Proceed with setup? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
            echo "Setup cancelled."
            exit 0
        fi
    fi
    
    echo
    create_env_file
    update_orthanc_json
    create_directories
    make_executable
    
    # Start services and configure
    start_services
    if [[ $? -eq 0 ]]; then
        seed_modalities
    fi
    
    print_completion
}

main "$@"
