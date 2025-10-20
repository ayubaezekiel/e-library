#!/bin/bash

# DSpace Docker Installation and Setup Script
# This script automates the installation of DSpace via Docker

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
print_message "Checking prerequisites..."

if ! command_exists docker; then
    print_error "Docker is not installed. Please install Docker Desktop first."
    echo "Windows: https://docs.docker.com/desktop/install/windows-install/"
    echo "Mac: https://docs.docker.com/desktop/install/mac-install/"
    echo "Linux: https://docs.docker.com/engine/install/"
    exit 1
fi

if ! command_exists git; then
    print_error "Git is not installed. Please install Git first."
    echo "Download from: https://git-scm.com/downloads"
    exit 1
fi

print_message "Prerequisites check passed!"

# Clone DSpace Angular repository
print_message "Cloning DSpace Angular repository..."
if [ -d "dspace-angular" ]; then
    print_warning "dspace-angular directory already exists. Skipping clone."
    cd dspace-angular
else
    git clone https://github.com/DSpace/dspace-angular.git
    cd dspace-angular
fi

# Switch to main branch
print_message "Switching to main branch..."
git checkout main

# Pull latest Docker images
print_message "Pulling latest Docker images (this may take a while)..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose-rest.yml pull

# Ask user if they want to rebuild Angular UI locally
read -p "Do you want to rebuild the Angular UI locally? (y/N): " rebuild_ui
if [[ $rebuild_ui =~ ^[Yy]$ ]]; then
    print_message "Building Angular UI Docker image..."
    docker compose -f docker/docker-compose.yml build
fi

# Start DSpace services
print_message "Starting DSpace services (REST API and Angular UI)..."
docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml up -d

print_message "Waiting for services to start (30 seconds)..."
sleep 30

# Ask user about test data
echo ""
print_message "Choose test data option:"
echo "1) Import AIP test data (recommended for quick setup)"
echo "2) Import Configurable Entities test data"
echo "3) Skip test data import"
read -p "Enter your choice (1/2/3): " data_choice

case $data_choice in
    1)
        print_message "Creating administrator account..."
        docker compose -p d9 -f docker/cli.yml run --rm dspace-cli create-administrator -e test@test.edu -f admin -l user -p admin -c en
        
        print_message "Importing AIP test data (this may take several minutes)..."
        docker compose -p d9 -f docker/cli.yml -f ./docker/cli.ingest.yml run --rm dspace-cli
        ;;
    2)
        print_message "Shutting down containers to load Entities test data..."
        docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml down
        
        print_warning "Removing existing volumes..."
        docker volume rm $(docker volume ls -q --filter name=d9) 2>/dev/null || true
        
        print_message "Starting containers with Entities test data..."
        docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml -f docker/db.entities.yml up -d
        
        print_message "Waiting for database to initialize (60 seconds)..."
        sleep 60
        
        print_message "Loading Entities test assetstore and reindexing..."
        docker compose -p d9 -f docker/cli.yml -f docker/cli.assetstore.yml run --rm dspace-cli
        ;;
    3)
        print_message "Skipping test data import..."
        ;;
    *)
        print_warning "Invalid choice. Skipping test data import..."
        ;;
esac

# Create administrator account if not already created
if [ "$data_choice" != "1" ]; then
    read -p "Create administrator account? (Y/n): " create_admin
    if [[ ! $create_admin =~ ^[Nn]$ ]]; then
        read -p "Enter admin email (default: test@test.edu): " admin_email
        admin_email=${admin_email:-test@test.edu}
        
        read -p "Enter admin password (default: admin): " admin_password
        admin_password=${admin_password:-admin}
        
        print_message "Creating administrator account..."
        docker compose -p d9 -f docker/cli.yml run --rm dspace-cli create-administrator -e "$admin_email" -f admin -l user -p "$admin_password" -c en
    fi
fi

# Display completion message
echo ""
echo "================================================"
print_message "DSpace installation complete!"
echo "================================================"
echo ""
echo "Access your DSpace instance at:"
echo "  User Interface: http://localhost:4000/"
echo "  REST API: http://localhost:8080/server/"
echo ""

if [ "$data_choice" != "3" ]; then
    echo "Admin Login:"
    if [ "$data_choice" == "1" ] || [ -z "$admin_email" ]; then
        echo "  Email: test@test.edu"
        echo "  Password: admin"
    else
        echo "  Email: $admin_email"
        echo "  Password: $admin_password"
    fi
    echo ""
fi

echo "Useful commands:"
echo "  View logs: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml logs -f"
echo "  Stop services: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml down"
echo "  Restart services: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml restart"
echo "  Clean up everything: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml down && docker system prune --volumes"
echo ""

# Ask if user wants to view logs
read -p "Would you like to view the logs now? (y/N): " view_logs
if [[ $view_logs =~ ^[Yy]$ ]]; then
    docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml logs -f
fi
