#!/bin/bash

# DSpace 8.x Installation Script
# Backend API on port 8080, Frontend UI on port 4000

set -e

# Configuration variables
DSPACE_VERSION="8.0"
DSPACE_USER="dspace"
DSPACE_DIR="/dspace"
DSPACE_SRC="/opt/dspace-src"
DB_NAME="dspace"
DB_USER="dspace"
DB_PASS="dspace_password_change_me"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

echo "=== DSpace ${DSPACE_VERSION} Installation ==="
echo ""

echo "=== Updating system ==="
apt-get update
apt-get upgrade -y

echo "=== Installing dependencies ==="
apt-get install -y \
    openjdk-17-jdk \
    postgresql \
    postgresql-contrib \
    postgresql-contrib-* \
    maven \
    ant \
    git \
    curl \
    wget \
    unzip

echo "=== Setting JAVA_HOME ==="
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

# Make JAVA_HOME persistent
echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> /etc/environment
echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> /etc/environment

# Set for dspace user
sudo -u "$DSPACE_USER" bash -c 'echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> ~/.bashrc'
sudo -u "$DSPACE_USER" bash -c 'echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> ~/.bashrc'

echo "=== Installing Node.js and Yarn for frontend ==="
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
npm install -g yarn

echo "=== Creating DSpace user ==="
if ! id "$DSPACE_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DSPACE_USER"
    echo "Created user: $DSPACE_USER"
else
    echo "User $DSPACE_USER already exists"
fi

echo "=== Configuring PostgreSQL ==="
sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 || \
sudo -u postgres psql <<EOF
CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
CREATE DATABASE $DB_NAME WITH OWNER $DB_USER ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
ALTER USER $DB_USER WITH SUPERUSER;
EOF

echo "=== Enabling pgcrypto extension ==="
sudo -u postgres psql -d "$DB_NAME" <<EOF
CREATE EXTENSION IF NOT EXISTS pgcrypto;
EOF

# Enable password authentication
PG_HBA="/etc/postgresql/*/main/pg_hba.conf"
if ! grep -q "dspace" $PG_HBA 2>/dev/null; then
    echo "local   $DB_NAME   $DB_USER   md5" | tee -a $(ls $PG_HBA)
fi
systemctl restart postgresql

echo "=== Downloading DSpace source ==="
mkdir -p "$DSPACE_SRC"
cd /opt

if [ ! -d "$DSPACE_SRC/.git" ]; then
    git clone https://github.com/DSpace/DSpace.git "$DSPACE_SRC"
    cd "$DSPACE_SRC"
    git checkout "dspace-${DSPACE_VERSION}"
else
    echo "DSpace source already exists"
    cd "$DSPACE_SRC"
fi

echo "=== Configuring DSpace ==="
cd "$DSPACE_SRC"

# Create local.cfg with basic configuration
cat > "$DSPACE_SRC/local.cfg" <<EOF
# DSpace installation directory
dspace.dir = $DSPACE_DIR

# Database configuration
db.url = jdbc:postgresql://localhost:5432/$DB_NAME
db.username = $DB_USER
db.password = $DB_PASS

# Server configuration
dspace.server.url = http://localhost:8080/server
dspace.ui.url = http://localhost:4000

# Admin email
mail.admin = admin@yourdomain.edu

# Basic mail server (configure properly for production)
mail.server = localhost
mail.from.address = noreply@yourdomain.edu

# Solr configuration
solr.server = http://localhost:8983/solr
EOF

echo "=== Building DSpace backend ==="
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH
mvn clean package -Dmicrometer.enabled=false

echo "=== Installing DSpace backend ==="
mkdir -p "$DSPACE_DIR"
cd "$DSPACE_SRC/dspace/target/dspace-installer"
ant fresh_install

echo "=== Setting permissions ==="
chown -R "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_DIR"
chown -R "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_SRC"

echo "=== Creating DSpace admin user ==="
sudo -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" create-administrator \
    -e admin@yourdomain.edu \
    -f DSpace -l Administrator \
    -p admin -c en

echo "=== Setting up frontend ==="
FRONTEND_DIR="/opt/dspace-angular"
if [ ! -d "$FRONTEND_DIR" ]; then
    cd /opt
    git clone https://github.com/DSpace/dspace-angular.git "$FRONTEND_DIR"
    cd "$FRONTEND_DIR"
    git checkout "dspace-${DSPACE_VERSION}"
    
    # Configure environment
    cat > "$FRONTEND_DIR/config/local.cfg" <<EOF
rest.host = localhost
rest.port = 8080
rest.nameSpace = /server
rest.ssl = false
ui.port = 4000
EOF
    
    yarn install
    chown -R "$DSPACE_USER":"$DSPACE_USER" "$FRONTEND_DIR"
else
    echo "Frontend already exists"
fi

echo "=== Creating systemd service for backend ==="
cat > /etc/systemd/system/dspace-backend.service <<EOF
[Unit]
Description=DSpace Backend (REST API)
After=postgresql.service

[Service]
Type=simple
User=$DSPACE_USER
WorkingDirectory=$DSPACE_DIR
ExecStart=$DSPACE_DIR/bin/dspace start
ExecStop=$DSPACE_DIR/bin/dspace stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "=== Creating systemd service for frontend ==="
cat > /etc/systemd/system/dspace-frontend.service <<EOF
[Unit]
Description=DSpace Frontend (Angular UI)
After=dspace-backend.service

[Service]
Type=simple
User=$DSPACE_USER
WorkingDirectory=$FRONTEND_DIR
ExecStart=/usr/bin/yarn start:prod
Restart=on-failure
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

echo "=== Enabling and starting services ==="
systemctl daemon-reload
systemctl enable dspace-backend
systemctl enable dspace-frontend
systemctl start dspace-backend

# Wait for backend to start
echo "Waiting for backend to start..."
sleep 30

systemctl start dspace-frontend

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Configuration details:"
echo "  DSpace directory: $DSPACE_DIR"
echo "  Source directory: $DSPACE_SRC"
echo "  Database: $DB_NAME"
echo "  DB User: $DB_USER"
echo "  DB Password: $DB_PASS"
echo ""
echo "Access URLs:"
echo "  Backend API: http://localhost:8080/server"
echo "  Frontend UI: http://localhost:4000"
echo ""
echo "Admin credentials:"
echo "  Email: admin@yourdomain.edu"
echo "  Password: admin"
echo ""
echo "Service management:"
echo "  Backend: sudo systemctl {start|stop|restart|status} dspace-backend"
echo "  Frontend: sudo systemctl {start|stop|restart|status} dspace-frontend"
echo ""
echo "⚠️  IMPORTANT: Change the admin password and database password!"
echo "⚠️  Configure proper email settings in local.cfg for production"
echo ""
