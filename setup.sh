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

# Defaults (from your original setup)
DEFAULT_DICOM_STORAGE="/opt/orthanc/orthanc-storage"
DEFAULT_POSTGRES_STORAGE="/opt/orthanc/postgres-data"
DEFAULT_ORTHANC_AET="ORTHANC_LPCH"
DEFAULT_ORTHANC_PASSWORD="helloaide123"
DEFAULT_POSTGRES_PASSWORD=""  # Will be generated if empty

# Parsed options
DICOM_STORAGE=""
POSTGRES_STORAGE=""
ORTHANC_AET=""
ORTHANC_PASSWORD=""
POSTGRES_PASSWORD=""
USE_DEFAULTS=false
NON_INTERACTIVE=false
USE_EXISTING=false
FORCE_SETUP=false

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
# PARSE ARGUMENTS
# ─────────────────────────────────────────────────────────────────────────────────

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
  --dicom PATH        DICOM storage path (default: $DEFAULT_DICOM_STORAGE)
  --db PATH           PostgreSQL data path (default: $DEFAULT_POSTGRES_STORAGE)
  --aet NAME          DICOM AE Title (default: $DEFAULT_ORTHANC_AET)
  --orthanc-pass PWD  Orthanc admin password (default: $DEFAULT_ORTHANC_PASSWORD)
  --db-pass PWD       PostgreSQL password (default: auto-generate)
  --defaults          Use all default values (non-interactive)
  --non-interactive   Skip all prompts
  --force             Overwrite existing configuration without prompting
  -h, --help          Show this help

EXAMPLES:
  $0                                          # Interactive setup
  $0 --defaults                               # Quick setup with defaults
  $0 --dicom /mnt/nas/orthanc/dicom           # Custom DICOM storage
  $0 --dicom /data/dicom --db /data/postgres  # Custom paths for both
  $0 --force --defaults                       # Re-setup without prompts

RE-RUNNING SETUP:
  It's safe to run setup again on an existing installation.
  You'll be prompted to update or keep the existing configuration.

ENVIRONMENT VARIABLES:
  You can also set these before running:
    DICOM_STORAGE=/path/to/dicom
    POSTGRES_STORAGE=/path/to/postgres
    ORTHANC_AET=MY_AET
    ORTHANC_PASSWORD=my_password
    POSTGRES_PASSWORD=db_password

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
                # Preserve existing storage paths as defaults
                DICOM_STORAGE="${existing_dicom_path:-$DEFAULT_DICOM_STORAGE}"
                POSTGRES_STORAGE="${existing_db_path:-$DEFAULT_POSTGRES_STORAGE}"
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
                echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${RED}║  🚨  DANGER: THIS WILL DELETE ALL YOUR DATA!                 ║${NC}"
                echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
                echo
                if [[ "$has_dicom_data" == true ]]; then
                    echo -e "  Will delete: ${RED}$dicom_size${NC} of DICOM files"
                fi
                if [[ "$has_db_data" == true ]]; then
                    echo -e "  Will delete: ${RED}$db_size${NC} of database"
                fi
                echo
                read -p "Type 'DELETE ALL DATA' to confirm: " confirm
                if [[ "$confirm" == "DELETE ALL DATA" ]]; then
                    log_warn "Deleting all existing data..."
                    docker compose down -v 2>/dev/null || true
                    [[ -n "$existing_dicom_path" ]] && rm -rf "$existing_dicom_path"/* 2>/dev/null
                    [[ -n "$existing_db_path" ]] && rm -rf "$existing_db_path"/* 2>/dev/null
                    rm -f .env 2>/dev/null
                    log_success "All data deleted. Proceeding with fresh install..."
                    return 0
                else
                    log_info "Cancelled. Your data is safe."
                    exit 0
                fi
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
        ORTHANC_AET="${ORTHANC_AET:-$DEFAULT_ORTHANC_AET}"
        ORTHANC_PASSWORD="${ORTHANC_PASSWORD:-$DEFAULT_ORTHANC_PASSWORD}"
        POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_password)}"
        return
    fi
    
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  STORAGE CONFIGURATION${NC}"
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
    
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  DICOM CONFIGURATION${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    # AE Title
    if [[ -z "$ORTHANC_AET" ]]; then
        echo -e "${YELLOW}DICOM AE Title (Application Entity Title)${NC}"
        prompt "AE Title" "$DEFAULT_ORTHANC_AET" ORTHANC_AET
    fi
    
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CREDENTIALS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    # Orthanc Password
    if [[ -z "$ORTHANC_PASSWORD" ]]; then
        prompt_password "Orthanc admin password" ORTHANC_PASSWORD "$DEFAULT_ORTHANC_PASSWORD"
    fi
    
    # PostgreSQL Password
    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        prompt_password "PostgreSQL password" POSTGRES_PASSWORD ""
    fi
}

show_summary() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CONFIGURATION SUMMARY${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${CYAN}Storage${NC}"
    echo "    DICOM:      $DICOM_STORAGE"
    echo "    PostgreSQL: $POSTGRES_STORAGE"
    echo
    echo -e "  ${CYAN}DICOM${NC}"
    echo "    AE Title:   $ORTHANC_AET"
    echo "    Port:       4242"
    echo
    echo -e "  ${CYAN}Web Ports${NC}"
    echo "    Dashboard:  8040"
    echo "    Orthanc:    8041"
    echo "    OHIF:       8042"
    echo "    PostgreSQL: 8043"
    echo
    echo -e "  ${CYAN}Credentials${NC}"
    echo "    Orthanc:    orthanc_admin / $ORTHANC_PASSWORD"
    echo "    PostgreSQL: orthanc / $POSTGRES_PASSWORD"
    echo
}

create_env_file() {
    log_info "Creating .env file..."
    
    cat > .env << EOF
# ═══════════════════════════════════════════════════════════════════════════════
# ORTHANC CONFIGURATION
# Generated by setup.sh on $(date)
# ═══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────────
# CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────────
ORTHANC_USERNAME=orthanc_admin
ORTHANC_PASSWORD=$ORTHANC_PASSWORD

POSTGRES_USER=orthanc
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# ─────────────────────────────────────────────────────────────────────────────────
# WEB PORTS
# ─────────────────────────────────────────────────────────────────────────────────
OPERATOR_UI_PORT=8040
ORTHANC_WEB_PORT=8041
OHIF_PORT=8042
POSTGRES_PORT=8043

# ─────────────────────────────────────────────────────────────────────────────────
# DICOM SETTINGS
# ─────────────────────────────────────────────────────────────────────────────────
ORTHANC_AET=$ORTHANC_AET
DICOM_PORT=4242

# ─────────────────────────────────────────────────────────────────────────────────
# STORAGE PATHS
# ─────────────────────────────────────────────────────────────────────────────────
DICOM_STORAGE=$DICOM_STORAGE
POSTGRES_STORAGE=$POSTGRES_STORAGE

# ─────────────────────────────────────────────────────────────────────────────────
# TIMEZONE
# ─────────────────────────────────────────────────────────────────────────────────
TZ=America/Los_Angeles
EOF

    chmod 600 .env
    log_success ".env file created"
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

create_directories() {
    log_info "Creating storage directories..."
    
    # DICOM storage
    if [[ ! -d "$DICOM_STORAGE" ]]; then
        if sudo mkdir -p "$DICOM_STORAGE" 2>/dev/null || mkdir -p "$DICOM_STORAGE" 2>/dev/null; then
            log_success "Created: $DICOM_STORAGE"
        else
            log_error "Failed to create: $DICOM_STORAGE"
            log_warn "You may need to create it manually with: sudo mkdir -p $DICOM_STORAGE"
        fi
    else
        log_success "Exists: $DICOM_STORAGE"
    fi
    
    # Set DICOM permissions (Orthanc runs as UID 1000)
    sudo chown -R 1000:1000 "$DICOM_STORAGE" 2>/dev/null || \
        chown -R 1000:1000 "$DICOM_STORAGE" 2>/dev/null || \
        log_warn "Could not set ownership on $DICOM_STORAGE"
    
    # PostgreSQL storage
    if [[ ! -d "$POSTGRES_STORAGE" ]]; then
        if sudo mkdir -p "$POSTGRES_STORAGE" 2>/dev/null || mkdir -p "$POSTGRES_STORAGE" 2>/dev/null; then
            log_success "Created: $POSTGRES_STORAGE"
        else
            log_error "Failed to create: $POSTGRES_STORAGE"
            log_warn "You may need to create it manually with: sudo mkdir -p $POSTGRES_STORAGE"
        fi
    else
        log_success "Exists: $POSTGRES_STORAGE"
    fi
    
    # Set PostgreSQL permissions (postgres runs as UID 999)
    sudo chown -R 999:999 "$POSTGRES_STORAGE" 2>/dev/null || \
        chown -R 999:999 "$POSTGRES_STORAGE" 2>/dev/null || \
        log_warn "Could not set ownership on $POSTGRES_STORAGE"
}

make_executable() {
    chmod +x orthanc 2>/dev/null || true
    chmod +x setup.sh 2>/dev/null || true
}

start_services() {
    log_info "Starting Docker services..."
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
    log_info "Configuring default DICOM modalities..."
    
    local port="${ORTHANC_WEB_PORT:-8041}"
    local orthanc_url="http://localhost:$port"
    local user="${ORTHANC_USERNAME:-orthanc_admin}"
    local pass="${ORTHANC_PASSWORD:-helloaide123}"
    local auth="$user:$pass"
    
    log_info "Connecting to Orthanc at $orthanc_url..."
    
    # Check current modalities
    local existing=$(curl -s -u "$auth" "$orthanc_url/modalities" 2>/dev/null)
    log_info "Current modalities: $existing"
    
    # Define default modalities (from your original config)
    # Format: NAME|AET|HOST|PORT
    local modalities=(
        "MERCURE|orthanc|172.17.0.1|11112"
        "LPCHROUTER|LPCHROUTER|10.50.133.21|4000"
        "LPCHTROUTER|LPCHTROUTER|10.50.130.114|4000"
        "MODLINK|PSRTBONEAPP01|10.251.201.59|104"
    )
    
    for modality in "${modalities[@]}"; do
        IFS='|' read -r name aet host port <<< "$modality"
        
        # Check if this modality already exists
        if echo "$existing" | grep -q "\"$name\""; then
            log_info "Modality $name already exists, skipping"
            continue
        fi
        
        local config="{\"AET\":\"$aet\",\"Host\":\"$host\",\"Port\":$port,\"AllowEcho\":true,\"AllowStore\":true}"
        
        if curl -s -u "$auth" -X PUT "$orthanc_url/modalities/$name" \
            -H "Content-Type: application/json" \
            -d "$config" &>/dev/null; then
            log_success "Added modality: $name ($aet @ $host:$port)"
        else
            log_warn "Failed to add modality: $name"
        fi
    done
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
    
    parse_args "$@"
    
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
