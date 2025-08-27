#!/bin/bash

# install_orthanc.sh - Automated Orthanc installation with PostgreSQL
# Usage: ./install_orthanc.sh
# Run this script from the directory containing docker-compose.yml, orthanc.json, etc.

set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORTHANC_DIR="/opt/orthanc"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🏥 Installing Orthanc with dedicated PostgreSQL...${NC}"

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
    
    sudo mkdir -p "$ORTHANC_DIR"/{postgres-data,orthanc-storage}
    
    # Set proper permissions
    sudo chown -R $USER:$USER "$ORTHANC_DIR"
    sudo chown 999:999 "$ORTHANC_DIR/postgres-data"  # PostgreSQL UID
    
    echo -e "${GREEN}✅ Directories created${NC}"
}

# Function to generate and configure PostgreSQL password
setup_database_password() {
    echo -e "${YELLOW}🔐 Generating secure database password...${NC}"
    
    # Generate new password
    local DB_PWD=$(generate_password)
    
    # Store password securely
    echo "ORTHANC_DB_PASSWORD=$DB_PWD" | sudo tee "$ORTHANC_DIR/.db_password" > /dev/null
    sudo chmod 600 "$ORTHANC_DIR/.db_password"
    
    echo -e "${YELLOW}🔧 Updating configuration files...${NC}"
    
    # Update docker-compose.yml - replace PostgreSQL password
    sed -i -e "s/POSTGRES_PASSWORD=orthanc_secure_password_2024/POSTGRES_PASSWORD=$DB_PWD/" "$SCRIPT_DIR/docker-compose.yml"
    
    # Update orthanc.json - replace PostgreSQL password
    sed -i -e "s/orthanc_secure_password_2024/$DB_PWD/" "$SCRIPT_DIR/orthanc.json"
    
    # Update docker-compose.yml - fix volume paths to use absolute paths
    sed -i -e "s|device: '/opt/mercure/addons/orthanc/orthanc-storage'|device: '$ORTHANC_DIR/orthanc-storage'|" "$SCRIPT_DIR/docker-compose.yml"
    sed -i -e "s|device: '/opt/mercure/addons/orthanc/postgres-data'|device: '$ORTHANC_DIR/postgres-data'|" "$SCRIPT_DIR/docker-compose.yml"
    
    echo -e "${GREEN}✅ Database password configured${NC}"
}

# Function to copy files to installation directory
copy_files() {
    echo -e "${YELLOW}📋 Copying configuration files...${NC}"
    
    # Copy all configuration files to the installation directory
    cp "$SCRIPT_DIR/docker-compose.yml" "$ORTHANC_DIR/"
    cp "$SCRIPT_DIR/orthanc.json" "$ORTHANC_DIR/"
    cp "$SCRIPT_DIR/nginx.conf" "$ORTHANC_DIR/"
    cp -r "$SCRIPT_DIR/lua-scripts" "$ORTHANC_DIR/"
    
    # Set proper ownership
    sudo chown -R $USER:$USER "$ORTHANC_DIR"
    sudo chown 999:999 "$ORTHANC_DIR/postgres-data"  # Reset PostgreSQL permissions
    
    echo -e "${GREEN}✅ Configuration files copied${NC}"
}

# Function to start services
start_services() {
    echo -e "${YELLOW}🚀 Starting Orthanc services...${NC}"
    
    cd "$ORTHANC_DIR"
    
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
    echo -e "  • $ORTHANC_DIR"
    echo -e "\n${YELLOW}🛠️  Management Commands:${NC}"
    echo -e "  • Start: cd $ORTHANC_DIR && docker-compose up -d"
    echo -e "  • Stop: cd $ORTHANC_DIR && docker-compose down"
    echo -e "  • Logs: cd $ORTHANC_DIR && docker-compose logs -f"
    echo -e "  • Status: cd $ORTHANC_DIR && docker-compose ps"
    echo -e "\n${YELLOW}📝 Next Steps:${NC}"
    echo -e "  • Access Orthanc at http://localhost:8042 to upload DICOM files"
    echo -e "  • Check logs if services don't respond immediately"
    echo -e "  • DICOM files will be stored in: $ORTHANC_DIR/orthanc-storage"
}

# Main execution
main() {
    echo -e "${GREEN}Starting Orthanc installation from: $SCRIPT_DIR${NC}"
    
    # check_root
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