#!/bin/bash

# install_orthanc.sh - Automated Orthanc installation with PostgreSQL
# Usage: ./install_orthanc.sh [DATA_PATH]
# Run this script from the directory containing docker-compose.yml, orthanc.json, etc.

set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ORTHANC_DIR="/opt/orthanc"

# Accept data path as command line argument or use default
ORTHANC_DIR="${1:-$DEFAULT_ORTHANC_DIR}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}🏥 Installing Orthanc with dedicated PostgreSQL...${NC}"
echo -e "${BLUE}📍 Data will be stored in: $ORTHANC_DIR${NC}"

# Function to generate secure password
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        echo -e "${RED}❌ This script should not be run as root${NC}"
        exit 1
    fi
}

# Function to validate and check data path
validate_data_path() {
    echo -e "${YELLOW}📋 Validating data path: $ORTHANC_DIR${NC}"
    
    # Check if path exists and is accessible
    if [[ ! -d "$ORTHANC_DIR" ]]; then
        echo -e "${YELLOW}📁 Directory doesn't exist, attempting to create...${NC}"
        if ! mkdir -p "$ORTHANC_DIR" 2>/dev/null; then
            echo -e "${RED}❌ Cannot create directory: $ORTHANC_DIR${NC}"
            echo -e "${YELLOW}💡 For network drives, ensure:${NC}"
            echo -e "   • The network drive is mounted"
            echo -e "   • You have write permissions"
            echo -e "   • The mount point exists"
            exit 1
        fi
    fi
    
    # Test write permissions
    local test_file="$ORTHANC_DIR/.write_test_$$"
    if ! touch "$test_file" 2>/dev/null; then
        echo -e "${RED}❌ No write permission to: $ORTHANC_DIR${NC}"
        echo -e "${YELLOW}💡 Try:${NC}"
        echo -e "   • sudo chown -R $USER:$USER $ORTHANC_DIR"
        echo -e "   • Check network drive mount permissions"
        exit 1
    fi
    rm -f "$test_file"
    
    # Check available space (warn if less than 10GB)
    local available_space
    available_space=$(df -BG "$ORTHANC_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ $available_space -lt 10 ]]; then
        echo -e "${YELLOW}⚠️  Warning: Less than 10GB available space (${available_space}GB)${NC}"
        echo -e "${YELLOW}   Medical imaging requires significant storage space${NC}"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo -e "${GREEN}✅ Data path validated${NC}"
}

# Function to check required files exist
check_files() {
    echo -e "${YELLOW}📋 Checking required files...${NC}"
    
    local required_files=("docker-compose.yml" "orthanc.json" "nginx.conf")
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
    echo -e "${YELLOW}📁 Creating Orthanc directories...${NC}"
    
    # Create subdirectories
    mkdir -p "$ORTHANC_DIR"/{postgres-data,orthanc-storage,config}
    
    # For network drives, we need to be more careful with permissions
    if mountpoint -q "$ORTHANC_DIR" 2>/dev/null || [[ "$ORTHANC_DIR" =~ ^/mnt/ ]] || [[ "$ORTHANC_DIR" =~ ^/media/ ]]; then
        echo -e "${BLUE}🌐 Network/mounted drive detected${NC}"
        # Set permissions that work with most network filesystems
        chmod -R 755 "$ORTHANC_DIR"
        
        # Create a special postgres directory with specific permissions
        # We'll use a user-accessible location for postgres data on network drives
        mkdir -p "$ORTHANC_DIR/postgres-data"
        chmod 777 "$ORTHANC_DIR/postgres-data"  # More permissive for network drives
    else
        # Local drive - use standard permissions
        chown -R $USER:$USER "$ORTHANC_DIR"
        # Note: PostgreSQL container will handle its own permissions
    fi
    
    echo -e "${GREEN}✅ Directories created${NC}"
}

# Function to generate and configure PostgreSQL password
setup_database_password() {
    echo -e "${YELLOW}🔐 Generating secure database password...${NC}"
    
    # Generate new password
    local DB_PWD=$(generate_password)
    
    # Store password securely
    echo "ORTHANC_DB_PASSWORD=$DB_PWD" > "$ORTHANC_DIR/.db_password"
    chmod 600 "$ORTHANC_DIR/.db_password" 2>/dev/null || chmod 644 "$ORTHANC_DIR/.db_password"  # Fallback for network drives
    
    echo -e "${YELLOW}🔧 Updating configuration files...${NC}"
    
    # Create a temporary docker-compose.yml with updated paths
    local temp_compose="$ORTHANC_DIR/docker-compose.yml"
    
    # Update docker-compose.yml - replace PostgreSQL password and paths
    sed -e "s/POSTGRES_PASSWORD=ChangePasswordHere/POSTGRES_PASSWORD=$DB_PWD/" \
        -e "s|device: '/opt/orthanc/orthanc-storage'|device: '$ORTHANC_DIR/orthanc-storage'|g" \
        -e "s|device: '/opt/orthanc/postgres-data'|device: '$ORTHANC_DIR/postgres-data'|g" \
        -e "s|device: '/opt/mercure/addons/orthanc/orthanc-storage'|device: '$ORTHANC_DIR/orthanc-storage'|g" \
        -e "s|device: '/opt/mercure/addons/orthanc/postgres-data'|device: '$ORTHANC_DIR/postgres-data'|g" \
        "$SCRIPT_DIR/docker-compose.yml" > "$temp_compose"
    
    # Update orthanc.json - replace PostgreSQL password
    sed -e "s/ChangePasswordHere/$DB_PWD/" \
        "$SCRIPT_DIR/orthanc.json" > "$ORTHANC_DIR/config/orthanc.json"
    
    echo -e "${GREEN}✅ Database password configured${NC}"
}

# Function to copy files to installation directory
copy_files() {
    echo -e "${YELLOW}📋 Copying configuration files...${NC}"
    
    # Copy nginx configuration
    cp "$SCRIPT_DIR/nginx.conf" "$ORTHANC_DIR/config/"
    
    # Copy lua scripts
    cp -r "$SCRIPT_DIR/lua-scripts" "$ORTHANC_DIR/config/"
    
    # Update the docker-compose.yml to use the config subdirectory
    sed -i -e "s|./orthanc.json|./config/orthanc.json|g" \
           -e "s|./nginx.conf|./config/nginx.conf|g" \
           -e "s|./lua-scripts|./config/lua-scripts|g" \
           "$ORTHANC_DIR/docker-compose.yml" 2>/dev/null || {
        # If sed -i doesn't work (some network filesystems), use temp file
        local temp_file=$(mktemp)
        sed -e "s|./orthanc.json|./config/orthanc.json|g" \
            -e "s|./nginx.conf|./config/nginx.conf|g" \
            -e "s|./lua-scripts|./config/lua-scripts|g" \
            "$ORTHANC_DIR/docker-compose.yml" > "$temp_file"
        mv "$temp_file" "$ORTHANC_DIR/docker-compose.yml"
    }
    
    echo -e "${GREEN}✅ Configuration files copied${NC}"
}

# Function to start services
start_services() {
    echo -e "${YELLOW}🚀 Starting Orthanc services...${NC}"
    
    cd "$ORTHANC_DIR"
    
    # For network drives, we might need to set COMPOSE_CONVERT_WINDOWS_PATHS
    export COMPOSE_CONVERT_WINDOWS_PATHS=1
    
    docker-compose up -d
    
    echo -e "${GREEN}✅ Services started${NC}"
    echo -e "${YELLOW}⏳ Waiting for services to initialize...${NC}"
    sleep 15
    
    # Check service status
    docker-compose ps
}

# Function to verify installation
verify_installation() {
    echo -e "${YELLOW}🔍 Verifying installation...${NC}"
    
    cd "$ORTHANC_DIR"
    
    # Check if containers are running
    if docker-compose ps | grep -q "Up"; then
        echo -e "${GREEN}✅ Containers are running${NC}"
        
        # Test Orthanc connectivity
        echo -e "${YELLOW}🏥 Testing Orthanc connectivity...${NC}"
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:8042 | grep -q "200\|302"; then
            echo -e "${GREEN}✅ Orthanc is accessible${NC}"
        else
            echo -e "${YELLOW}⚠️  Orthanc may still be starting up...${NC}"
        fi
        
        # Test database connectivity
        echo -e "${YELLOW}🗄️  Checking database logs...${NC}"
        if docker-compose logs orthanc-db | grep -q "database system is ready"; then
            echo -e "${GREEN}✅ Database is ready${NC}"
        else
            echo -e "${YELLOW}⚠️  Database may still be initializing...${NC}"
        fi
    else
        echo -e "${RED}❌ Some containers failed to start${NC}"
        docker-compose logs
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
    echo -e "  • Database password stored in: $ORTHANC_DIR/.db_password"
    echo -e "\n${YELLOW}📁 Installation Directory:${NC}"
    echo -e "  • Config: $ORTHANC_DIR/config/"
    echo -e "  • Data Storage: $ORTHANC_DIR/orthanc-storage/"
    echo -e "  • Database: $ORTHANC_DIR/postgres-data/"
    echo -e "\n${YELLOW}🛠️  Management Commands:${NC}"
    echo -e "  • Start: cd $ORTHANC_DIR && docker-compose up -d"
    echo -e "  • Stop: cd $ORTHANC_DIR && docker-compose down"
    echo -e "  • Logs: cd $ORTHANC_DIR && docker-compose logs -f"
    echo -e "  • Status: cd $ORTHANC_DIR && docker-compose ps"
    echo -e "\n${YELLOW}📝 Next Steps:${NC}"
    echo -e "  • Access Orthanc at http://localhost:8042 to upload DICOM files"
    echo -e "  • Check logs if services don't respond immediately"
    echo -e "  • DICOM files will be stored in: $ORTHANC_DIR/orthanc-storage"
    
    if mountpoint -q "$ORTHANC_DIR" 2>/dev/null || [[ "$ORTHANC_DIR" =~ ^/mnt/ ]] || [[ "$ORTHANC_DIR" =~ ^/media/ ]]; then
        echo -e "\n${BLUE}🌐 Network Drive Notes:${NC}"
        echo -e "  • Ensure the network drive remains mounted"
        echo -e "  • Consider adding to /etc/fstab for persistent mounting"
        echo -e "  • Monitor network connectivity for optimal performance"
    fi
}

# Function to show usage
show_usage() {
    echo -e "${YELLOW}Usage:${NC}"
    echo -e "  $0 [DATA_PATH]"
    echo -e ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0                           # Use default path (/opt/orthanc)"
    echo -e "  $0 /mnt/nas/orthanc         # Use network drive"
    echo -e "  $0 /home/user/orthanc-data  # Use user directory"
    echo -e "  $0 /media/external/orthanc  # Use external drive"
}

# Main execution
main() {
    # Show usage if help requested
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi
    
    echo -e "${GREEN}Starting Orthanc installation from: $SCRIPT_DIR${NC}"
    echo -e "${BLUE}Target data directory: $ORTHANC_DIR${NC}"
    
    # check_root
    validate_data_path
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