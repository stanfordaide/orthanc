#!/bin/bash

# install_orthanc.sh - Automated Orthanc installation with PostgreSQL
# Usage: ./install_orthanc.sh [DICOM_STORAGE_PATH]
# Run this script from the directory containing docker-compose.yml, orthanc.json, etc.
# PostgreSQL data stays local, only DICOM storage uses the provided path

set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DICOM_STORAGE="/opt/orthanc/dicom-storage"
DEFAULT_LOCAL_DIR="/opt/orthanc"

# Accept DICOM storage path as command line argument or use default
DICOM_STORAGE_DIR="${1:-$DEFAULT_DICOM_STORAGE}"
LOCAL_INSTALL_DIR="$DEFAULT_LOCAL_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}🏥 Installing Orthanc with dedicated PostgreSQL...${NC}"
echo -e "${BLUE}📍 DICOM storage: $DICOM_STORAGE_DIR${NC}"
echo -e "${BLUE}📍 Local config/DB: $LOCAL_INSTALL_DIR${NC}"

# Function to generate secure password
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  Running as root - please ensure proper permissions${NC}"
        # Don't exit, just warn
    fi
}

# Function to validate DICOM storage path
validate_dicom_storage_path() {
    echo -e "${YELLOW}📋 Validating DICOM storage path: $DICOM_STORAGE_DIR${NC}"
    
    # Check if path exists and is accessible
    if [[ ! -d "$DICOM_STORAGE_DIR" ]]; then
        echo -e "${YELLOW}📁 Directory doesn't exist, attempting to create...${NC}"
        if ! mkdir -p "$DICOM_STORAGE_DIR" 2>/dev/null; then
            echo -e "${RED}❌ Cannot create directory: $DICOM_STORAGE_DIR${NC}"
            echo -e "${YELLOW}💡 For network drives, ensure:${NC}"
            echo -e "   • The network drive is mounted"
            echo -e "   • You have write permissions"
            echo -e "   • The mount point exists"
            exit 1
        fi
    fi
    
    # Test write permissions
    local test_file="$DICOM_STORAGE_DIR/.write_test_$$"
    if ! touch "$test_file" 2>/dev/null; then
        echo -e "${RED}❌ No write permission to: $DICOM_STORAGE_DIR${NC}"
        echo -e "${YELLOW}💡 Try:${NC}"
        echo -e "   • chown -R \$USER:\$USER $DICOM_STORAGE_DIR"
        echo -e "   • Check network drive mount permissions"
        exit 1
    fi
    rm -f "$test_file"
    
    # Check available space (warn if less than 10GB)
    local available_space
    available_space=$(df -BG "$DICOM_STORAGE_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
    if [[ $available_space -lt 10 && $available_space -ne 0 ]]; then
        echo -e "${YELLOW}⚠️  Warning: Less than 10GB available space (${available_space}GB)${NC}"
        echo -e "${YELLOW}   Medical imaging requires significant storage space${NC}"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo -e "${GREEN}✅ DICOM storage path validated${NC}"
}

# Function to validate local installation path
validate_local_install_path() {
    echo -e "${YELLOW}📋 Validating local installation path: $LOCAL_INSTALL_DIR${NC}"
    
    # Check if we can create/access the local directory
    if [[ ! -d "$LOCAL_INSTALL_DIR" ]]; then
        echo -e "${YELLOW}📁 Creating local installation directory...${NC}"
        if ! mkdir -p "$LOCAL_INSTALL_DIR" 2>/dev/null; then
            echo -e "${RED}❌ Cannot create local directory: $LOCAL_INSTALL_DIR${NC}"
            echo -e "${YELLOW}💡 You may need to run with sudo or choose a different path${NC}"
            exit 1
        fi
    fi
    
    # Test write permissions to local directory
    local test_file="$LOCAL_INSTALL_DIR/.write_test_$$"
    if ! touch "$test_file" 2>/dev/null; then
        echo -e "${RED}❌ No write permission to: $LOCAL_INSTALL_DIR${NC}"
        exit 1
    fi
    rm -f "$test_file"
    
    echo -e "${GREEN}✅ Local installation path validated${NC}"
}

# Function to check required files exist
check_files() {
    echo -e "${YELLOW}📋 Checking required files...${NC}"
    
    local required_files=("docker-compose.yml" "orthanc.json" "nginx.conf" "orthanc-manager.sh")
    local missing_files=()
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo -e "${RED}❌ Missing required files:${NC}"
        printf '   • %s\n' "${missing_files[@]}"
        echo -e "${YELLOW}Make sure you're running this script from the directory containing:${NC}"
        printf '   • %s\n' "${required_files[@]}"
        echo -e "   • lua-scripts/ (directory)"
        exit 1
    fi
    
    if [[ ! -d "$SCRIPT_DIR/lua-scripts" ]]; then
        echo -e "${YELLOW}⚠️  lua-scripts directory not found, creating...${NC}"
        mkdir -p "$SCRIPT_DIR/lua-scripts"
    fi
    
    echo -e "${GREEN}✅ All required files found${NC}"
}

# Function to create target directories
create_directories() {
    echo -e "${YELLOW}📁 Creating directories...${NC}"
    
    # Create local directories (postgres-data only, since we'll keep files in root)
    mkdir -p "$LOCAL_INSTALL_DIR/postgres-data"
    
    # Create DICOM storage directory
    mkdir -p "$DICOM_STORAGE_DIR"
    
    # Set permissions for local directories
    if [[ $EUID -eq 0 ]]; then
        # Running as root, set proper ownership for local dirs
        chown -R 1000:1000 "$LOCAL_INSTALL_DIR" 2>/dev/null || true
    else
        chown -R $USER:$USER "$LOCAL_INSTALL_DIR" 2>/dev/null || true
    fi
    
    # Set permissions for DICOM storage (handle network drives)
    if mountpoint -q "$DICOM_STORAGE_DIR" 2>/dev/null || [[ "$DICOM_STORAGE_DIR" =~ ^/mnt/ ]] || [[ "$DICOM_STORAGE_DIR" =~ ^/media/ ]]; then
        echo -e "${BLUE}🌐 Network/mounted drive detected for DICOM storage${NC}"
        # Set permissions that work with most network filesystems
        chmod -R 755 "$DICOM_STORAGE_DIR" 2>/dev/null || true
    else
        # Local drive - use standard permissions
        if [[ $EUID -eq 0 ]]; then
            chown -R 1000:1000 "$DICOM_STORAGE_DIR" 2>/dev/null || true
        else
            chown -R $USER:$USER "$DICOM_STORAGE_DIR" 2>/dev/null || true
        fi
    fi
    
    echo -e "${GREEN}✅ Directories created${NC}"
}

# Function to generate and configure PostgreSQL password
setup_database_password() {
    echo -e "${YELLOW}🔐 Generating secure database password...${NC}"
    
    # Generate new password
    local DB_PWD=$(generate_password)
    
    # Store password securely in local directory
    echo "ORTHANC_DB_PASSWORD=$DB_PWD" > "$LOCAL_INSTALL_DIR/.db_password"
    chmod 600 "$LOCAL_INSTALL_DIR/.db_password" 2>/dev/null || chmod 644 "$LOCAL_INSTALL_DIR/.db_password"
    
    echo -e "${YELLOW}🔧 Updating configuration files...${NC}"
    
    # Update docker-compose.yml - replace PostgreSQL password and volume device paths
    sed -e "s/POSTGRES_PASSWORD=ChangePasswordHere/POSTGRES_PASSWORD=$DB_PWD/" \
        -e "s|device: '/opt/orthanc/orthanc-storage'|device: '$DICOM_STORAGE_DIR'|g" \
        -e "s|device: '/opt/orthanc/postgres-data'|device: '$LOCAL_INSTALL_DIR/postgres-data'|g" \
        "$SCRIPT_DIR/docker-compose.yml" > "$LOCAL_INSTALL_DIR/docker-compose.yml"
    
    # Update orthanc.json - replace PostgreSQL password
    sed -e "s/ChangePasswordHere/$DB_PWD/" \
        "$SCRIPT_DIR/orthanc.json" > "$LOCAL_INSTALL_DIR/orthanc.json"
    
    echo -e "${GREEN}✅ Database password configured${NC}"
}

# Function to copy files to installation directory
copy_files() {
    echo -e "${YELLOW}📋 Copying configuration files...${NC}"
    
    # Copy nginx configuration to root (docker-compose expects ./nginx.conf)
    cp "$SCRIPT_DIR/nginx.conf" "$LOCAL_INSTALL_DIR/"
    
    # Copy lua scripts to root (docker-compose expects ./lua-scripts)
    cp -r "$SCRIPT_DIR/lua-scripts" "$LOCAL_INSTALL_DIR/"
    
    # Copy orthanc-manager.sh to the local installation directory
    cp "$SCRIPT_DIR/orthanc-manager.sh" "$LOCAL_INSTALL_DIR/"
    
    echo -e "${GREEN}✅ Configuration files copied${NC}"
}

# Function to start services
start_services() {
    echo -e "${YELLOW}🚀 Starting Orthanc services...${NC}"
    
    cd "$LOCAL_INSTALL_DIR"
    
    # For network drives, we might need to set COMPOSE_CONVERT_WINDOWS_PATHS
    export COMPOSE_CONVERT_WINDOWS_PATHS=1
    
    echo -e "${BLUE}Debug: Working directory: $(pwd)${NC}"
    echo -e "${BLUE}Debug: Files in directory:${NC}"
    ls -la "$LOCAL_INSTALL_DIR/"
    
    docker compose up -d
    
    echo -e "${GREEN}✅ Services started${NC}"
    echo -e "${YELLOW}⏳ Waiting for services to initialize...${NC}"
    sleep 15
    
    # Check service status
    docker compose ps
}

# Function to verify installation
verify_installation() {
    echo -e "${YELLOW}🔍 Verifying installation...${NC}"
    
    cd "$LOCAL_INSTALL_DIR"
    
    # Check if containers are running
    if docker compose ps | grep -q "Up"; then
        echo -e "${GREEN}✅ Containers are running${NC}"
        
        # Test Orthanc connectivity
        echo -e "${YELLOW}🏥 Testing Orthanc connectivity...${NC}"
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8042 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
            echo -e "${GREEN}✅ Orthanc is accessible${NC}"
        else
            echo -e "${YELLOW}⚠️  Orthanc may still be starting up (HTTP: $http_code)...${NC}"
        fi
        
        # Test database connectivity
        echo -e "${YELLOW}🗄️  Checking database logs...${NC}"
        if docker compose logs orthanc-db | grep -q "database system is ready"; then
            echo -e "${GREEN}✅ Database is ready${NC}"
        else
            echo -e "${YELLOW}⚠️  Database may still be initializing...${NC}"
        fi
        
        # Check actual data directory contents
        echo -e "${YELLOW}📁 Checking directories...${NC}"
        if [[ -d "$DICOM_STORAGE_DIR" ]]; then
            echo -e "${GREEN}✅ DICOM storage directory exists: $DICOM_STORAGE_DIR${NC}"
        fi
        if [[ -d "$LOCAL_INSTALL_DIR/postgres-data" ]]; then
            echo -e "${GREEN}✅ PostgreSQL data directory exists: $LOCAL_INSTALL_DIR/postgres-data${NC}"
        fi
        
    else
        echo -e "${RED}❌ Some containers failed to start${NC}"
        docker compose logs
    fi
}


# Function to display completion message
show_completion() {
    echo -e "\n${GREEN}🎉 Orthanc installation completed successfully!${NC}"
    echo -e "\n${YELLOW}📋 Service Information:${NC}"
    echo -e "  • Orthanc Web UI: http://localhost:8042"
    echo -e "  • OHIF Viewer: http://localhost:8008"
    echo -e "  • DICOM Port: 4242"
    echo -e "  • PostgreSQL: localhost:5433"
    echo -e "\n${YELLOW}🔐 Security Information:${NC}"
    echo -e "  • Database password stored in: $LOCAL_INSTALL_DIR/.db_password"
    echo -e "\n${YELLOW}📁 Installation Directories:${NC}"
    echo -e "  • Main Installation: $LOCAL_INSTALL_DIR"
    echo -e "  • PostgreSQL Data (local): $LOCAL_INSTALL_DIR/postgres-data/"
    echo -e "  • DICOM Storage: $DICOM_STORAGE_DIR"
    echo -e "\n${YELLOW}🛠️  Management Commands:${NC}"
    echo -e "  • Start: cd $LOCAL_INSTALL_DIR && docker-compose up -d"
    echo -e "  • Stop: cd $LOCAL_INSTALL_DIR && docker-compose down"
    echo -e "  • Logs: cd $LOCAL_INSTALL_DIR && docker-compose logs -f"
    echo -e "  • Status: cd $LOCAL_INSTALL_DIR && docker-compose ps"
    echo -e "  • Manage Orthanc: cd $LOCAL_INSTALL_DIR && ./orthanc-manager.sh [command]"
    echo -e "\n${YELLOW}📝 Next Steps:${NC}"
    echo -e "  • Access Orthanc at http://localhost:8042 to upload DICOM files"
    echo -e "  • Check logs if services don't respond immediately"
    echo -e "  • DICOM files will be stored in: $DICOM_STORAGE_DIR"
    
    if mountpoint -q "$DICOM_STORAGE_DIR" 2>/dev/null || [[ "$DICOM_STORAGE_DIR" =~ ^/mnt/ ]] || [[ "$DICOM_STORAGE_DIR" =~ ^/media/ ]]; then
        echo -e "\n${BLUE}🌐 Network Drive Notes:${NC}"
        echo -e "  • DICOM storage is on a network/mounted drive"
        echo -e "  • Ensure the network drive remains mounted"
        echo -e "  • Consider adding to /etc/fstab for persistent mounting"
        echo -e "  • Monitor network connectivity for optimal performance"
        echo -e "  • PostgreSQL data remains local for optimal database performance"
    fi
    
    echo -e "\n${BLUE}🔍 Verification Commands:${NC}"
    echo -e "  • Check volumes: docker volume ls | grep $(basename $LOCAL_INSTALL_DIR)"
    echo -e "  • Check DICOM storage: ls -la $DICOM_STORAGE_DIR/"
    echo -e "  • Check database: ls -la $LOCAL_INSTALL_DIR/postgres-data/"
    echo -e "  • View password: cat $LOCAL_INSTALL_DIR/.db_password"
    
    echo -e "\n${GREEN}📊 Storage Architecture:${NC}"
    echo -e "  • Database (PostgreSQL): Local storage for performance"
    echo -e "  • DICOM Files: Network/external storage for capacity"
    echo -e "  • Configuration: Local storage for reliability"
}

# Function to show usage
show_usage() {
    echo -e "${YELLOW}Usage:${NC}"
    echo -e "  $0 [DICOM_STORAGE_PATH]"
    echo -e ""
    echo -e "${YELLOW}Description:${NC}"
    echo -e "  Installs Orthanc with PostgreSQL database stored locally"
    echo -e "  and DICOM files stored in the specified directory."
    echo -e ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0                           # Use default path (/opt/orthanc/dicom-storage)"
    echo -e "  $0 /data                     # Store DICOM files in /data"
    echo -e "  $0 /mnt/nas/orthanc         # Use network drive for DICOM storage"
    echo -e "  $0 /home/user/dicom-data    # Use user directory for DICOM storage"
    echo -e "  $0 /media/external/dicom    # Use external drive for DICOM storage"
    echo -e ""
    echo -e "${YELLOW}Notes:${NC}"
    echo -e "  • PostgreSQL data always stays in /opt/orthanc/postgres-data (local)"
    echo -e "  • Configuration files stay in /opt/orthanc/ (local)"
    echo -e "  • Only DICOM storage location is configurable"
    echo -e "  • This provides optimal database performance with flexible storage"
}

# Main execution
main() {
    # Show usage if help requested
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi
    
    echo -e "${GREEN}Starting Orthanc installation from: $SCRIPT_DIR${NC}"
    echo -e "${BLUE}DICOM storage directory: $DICOM_STORAGE_DIR${NC}"
    echo -e "${BLUE}Local installation directory: $LOCAL_INSTALL_DIR${NC}"
    
    check_root
    validate_dicom_storage_path
    validate_local_install_path
    check_files
    create_directories
    setup_database_password
    copy_files
    start_services
    verify_installation
    show_completion
}

# Run main function
main "$@"