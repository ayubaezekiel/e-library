#!/bin/bash

##############################################################################
# DSpace 8 Automated Installation Script for Ubuntu 24.04 LTS
# This script automates the installation of DSpace 8 with all dependencies
##############################################################################

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables
DSPACE_USER="dspace"
DSPACE_DIR="/dspace"
BUILD_DIR="/build"
DSPACE_VERSION="8.0"
SOLR_VERSION="8.11.4"
POSTGRES_VERSION="16"

# Prompt for configuration
echo -e "${GREEN}=== DSpace 8 Installation Configuration ===${NC}"
read -p "Enter DSpace user password: " -s DSPACE_USER_PASSWORD
echo
read -p "Enter PostgreSQL postgres user password: " -s POSTGRES_PASSWORD
echo
read -p "Enter DSpace database password: " -s DB_PASSWORD
echo
read -p "Enter DSpace server URL (e.g., http://localhost:8080/server): " DSPACE_SERVER_URL
read -p "Enter DSpace frontend URL (e.g., http://localhost:4000): " DSPACE_UI_URL
read -p "Enter site name (e.g., DSpace at My University): " SITE_NAME
read -p "Enter admin email: " ADMIN_EMAIL
read -p "Enter admin first name: " ADMIN_FIRSTNAME
read -p "Enter admin last name: " ADMIN_LASTNAME
read -p "Enter admin password: " -s ADMIN_PASSWORD
echo

# Function to print status messages
print_status() {
    echo -e "${GREEN}[*] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run this script as root or with sudo"
    exit 1
fi

print_status "Starting DSpace 8 installation..."

# Update system
print_status "Updating system packages..."
apt update && apt upgrade -y

# Create DSpace user
print_status "Creating DSpace user..."
if id "$DSPACE_USER" &>/dev/null; then
    print_warning "User $DSPACE_USER already exists, skipping creation"
else
    useradd -m "$DSPACE_USER"
    echo "$DSPACE_USER:$DSPACE_USER_PASSWORD" | chpasswd
    usermod -aG sudo "$DSPACE_USER"
fi

# Create DSpace directory
print_status "Creating DSpace directory..."
mkdir -p "$DSPACE_DIR"
chown "$DSPACE_USER" "$DSPACE_DIR"

# Install basic packages
print_status "Installing basic packages..."
apt install -y wget curl git build-essential zip unzip

# Install OpenJDK 17
print_status "Installing OpenJDK 17..."
apt install -y openjdk-17-jdk

# Set JAVA_HOME
print_status "Setting JAVA_HOME environment variable..."
cat >> /etc/environment << EOF
JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
JAVA_OPTS="-Xmx512M -Xms64M -Dfile.encoding=UTF-8"
EOF
source /etc/environment
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
export JAVA_OPTS="-Xmx512M -Xms64M -Dfile.encoding=UTF-8"

# Install Maven and Ant
print_status "Installing Maven and Ant..."
apt install -y maven ant

# Install PostgreSQL
print_status "Installing PostgreSQL..."
apt-get install -y postgresql postgresql-client postgresql-contrib libpostgresql-jdbc-java

# Configure PostgreSQL
print_status "Configuring PostgreSQL..."
systemctl start postgresql
systemctl enable postgresql

# Set PostgreSQL postgres user password
sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$POSTGRES_PASSWORD';"

# Configure PostgreSQL connection settings
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" /etc/postgresql/$POSTGRES_VERSION/main/postgresql.conf

# Add DSpace configuration to pg_hba.conf
if ! grep -q "DSpace configuration" /etc/postgresql/$POSTGRES_VERSION/main/pg_hba.conf; then
    sed -i '/# Database administrative login by Unix domain socket/a #DSpace configuration\nhost dspace dspace 127.0.0.1 255.255.255.255 md5' /etc/postgresql/$POSTGRES_VERSION/main/pg_hba.conf
fi

systemctl restart postgresql

# Install Solr
print_status "Installing Solr $SOLR_VERSION..."
cd ~
wget -q https://downloads.apache.org/lucene/solr/$SOLR_VERSION/solr-$SOLR_VERSION.zip
unzip -q solr-$SOLR_VERSION.zip
bash solr-$SOLR_VERSION/bin/install_solr_service.sh solr-$SOLR_VERSION.zip
systemctl enable solr
systemctl start solr

# Create build directory
print_status "Creating build directory..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Download DSpace
print_status "Downloading DSpace $DSPACE_VERSION..."
wget -q https://github.com/DSpace/DSpace/archive/refs/tags/dspace-$DSPACE_VERSION.zip
unzip -q dspace-$DSPACE_VERSION.zip
chmod 777 -R "$BUILD_DIR"

# Install Tomcat
print_status "Installing Tomcat 10..."
apt install -y tomcat10

# Configure Tomcat
print_status "Configuring Tomcat..."
if ! grep -q "ReadWritePaths=$DSPACE_DIR" /lib/systemd/system/tomcat10.service; then
    sed -i '/\[Service\]/a ReadWritePaths=/dspace' /lib/systemd/system/tomcat10.service
fi

# Update Tomcat server.xml
print_status "Updating Tomcat server.xml..."
sed -i '/<Connector port="8080" protocol="HTTP\/1.1"/,/redirectPort="8443" \/>/s/^/<!-- /' /etc/tomcat10/server.xml
sed -i '/<Connector port="8080" protocol="HTTP\/1.1"/,/redirectPort="8443" \/>/s/$/ -->/' /etc/tomcat10/server.xml

# Add new connector configuration
cat >> /etc/tomcat10/server.xml << 'EOF'
    <Connector port="8080" protocol="HTTP/1.1"
               minSpareThreads="25"
               enableLookups="false"
               redirectPort="8443"
               connectionTimeout="20000"
               disableUploadTimeout="true"
               URIEncoding="UTF-8"/>
EOF

systemctl daemon-reload
systemctl restart tomcat10

# Setup DSpace database
print_status "Setting up DSpace database..."
sudo -u postgres createuser --no-superuser --pwprompt dspace << EOF
$DB_PASSWORD
$DB_PASSWORD
EOF

sudo -u postgres createdb --owner=dspace --encoding=UNICODE dspace
sudo -u postgres psql dspace -c "CREATE EXTENSION pgcrypto;"

# Configure DSpace
print_status "Configuring DSpace..."
cd "$BUILD_DIR/DSpace-dspace-$DSPACE_VERSION/dspace/config"
cp local.cfg.EXAMPLE local.cfg

# Update local.cfg
cat > local.cfg << EOF
dspace.server.url = $DSPACE_SERVER_URL
dspace.ui.url = $DSPACE_UI_URL
dspace.name = $SITE_NAME
db.username = dspace
db.password = $DB_PASSWORD
solr.server = http://localhost:8983/solr
EOF

# Build DSpace
print_status "Building DSpace (this may take 10-20 minutes)..."
cd "$BUILD_DIR/DSpace-dspace-$DSPACE_VERSION"
mvn package -q

# Install DSpace Backend
print_status "Installing DSpace backend..."
cd dspace/target/dspace-installer
ant fresh_install

# Deploy DSpace to Tomcat
print_status "Deploying DSpace to Tomcat..."
cp -R "$DSPACE_DIR/webapps/"* /var/lib/tomcat10/webapps/
cp -R "$DSPACE_DIR/solr/"* /var/solr/data/
chown -R solr:solr /var/solr/data
systemctl restart solr

# Initialize database
print_status "Initializing DSpace database..."
cd "$DSPACE_DIR/bin"
./dspace database migrate

# Create administrator account
print_status "Creating DSpace administrator account..."
"$DSPACE_DIR/bin/dspace" create-administrator -e "$ADMIN_EMAIL" -f "$ADMIN_FIRSTNAME" -l "$ADMIN_LASTNAME" -p "$ADMIN_PASSWORD" -c en

# Set permissions
print_status "Setting permissions..."
chown -R tomcat:tomcat "$DSPACE_DIR"
systemctl restart tomcat10

# Install Node.js and dependencies
print_status "Installing Node.js and npm..."
apt install -y nodejs npm

print_status "Installing Yarn and PM2..."
npm install --global yarn
npm install --global pm2

# Install DSpace Angular frontend
print_status "Installing DSpace Angular frontend..."
cd /home/$DSPACE_USER
wget -q https://github.com/DSpace/dspace-angular/archive/refs/tags/dspace-$DSPACE_VERSION.zip
unzip -q dspace-$DSPACE_VERSION.zip
rm dspace-$DSPACE_VERSION.zip

cd /home/$DSPACE_USER/dspace-angular-dspace-$DSPACE_VERSION

# Install frontend dependencies
print_status "Installing frontend dependencies (this may take several minutes)..."
yarn install

# Configure frontend
print_status "Configuring frontend..."
cd config
cp config.example.yml config.prod.yml

cat > config.prod.yml << 'EOF'
rest:
  ssl: false
  host: localhost
  port: 8080
  nameSpace: /server
EOF

# Build frontend
print_status "Building frontend (this requires at least 5-6GB RAM and may take several minutes)..."
cd /home/$DSPACE_USER/dspace-angular-dspace-$DSPACE_VERSION
yarn run build:prod

# Create PM2 configuration
print_status "Creating PM2 configuration..."
cat > /home/$DSPACE_USER/dspace-angular-dspace-$DSPACE_VERSION/dspace-ui.json << EOF
{
    "apps": [
        {
           "name": "dspace-ui",
           "cwd": "/home/$DSPACE_USER/dspace-angular-dspace-$DSPACE_VERSION/",
           "script": "dist/server/main.js",
           "instances": "max",
           "exec_mode": "cluster",
           "env": {
              "NODE_ENV": "production"
           }
        }
    ]
}
EOF

# Start frontend with PM2
print_status "Starting DSpace frontend..."
pm2 start /home/$DSPACE_USER/dspace-angular-dspace-$DSPACE_VERSION/dspace-ui.json

# Setup PM2 autostart
print_status "Setting up PM2 autostart..."
(crontab -l 2>/dev/null; echo "@reboot bash -ci 'pm2 start /home/$DSPACE_USER/dspace-angular-dspace-$DSPACE_VERSION/dspace-ui.json'") | crontab -

# Install PM2 log rotation
print_status "Setting up PM2 log rotation..."
pm2 install pm2-logrotate
pm2 set pm2-logrotate:max_size 1000K
pm2 set pm2-logrotate:compress true
pm2 set pm2-logrotate:rotateInterval '0 0 19 1 1 7'

# Cleanup
print_status "Cleaning up build directory..."
rm -rf "$BUILD_DIR"
cd ~
rm -f solr-$SOLR_VERSION.zip

print_status "Installation complete!"
echo
echo -e "${GREEN}=== DSpace 8 Installation Summary ===${NC}"
echo "Backend REST API: $DSPACE_SERVER_URL"
echo "Frontend UI: $DSPACE_UI_URL"
echo "Admin Email: $ADMIN_EMAIL"
echo
echo "Access DSpace at: $DSPACE_UI_URL"
echo "Access REST API at: $DSPACE_SERVER_URL"
echo
echo -e "${YELLOW}Please reboot your system to ensure all services start correctly.${NC}"
echo "After reboot, check services status:"
echo "  sudo systemctl status postgresql"
echo "  sudo systemctl status solr"
echo "  sudo systemctl status tomcat10"
echo "  sudo pm2 status"
