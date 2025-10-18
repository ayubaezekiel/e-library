#!/bin/bash

# DSpace 9.x Installation Script (Following Official Documentation)
# Based on: https://wiki.lyrasis.org/display/DSDOC9x/Installing+DSpace

set -e

# Configuration variables
DSPACE_VERSION="9.1"
DSPACE_USER="dspace"
DSPACE_DIR="/dspace"
DSPACE_SRC="/opt/dspace-source"
DSPACE_UI="/opt/dspace-angular"
DB_NAME="dspace"
DB_USER="dspace"
DB_PASS="dspace_password_change_me"
SOLR_DIR="/opt/solr"
SOLR_VERSION="9.8.0"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

echo "=== DSpace ${DSPACE_VERSION} Installation Script ==="
echo ""

# ==========================================
# BACKEND INSTALLATION
# ==========================================

echo "=== STEP 1: Installing Backend Prerequisites ==="

echo "Updating system packages..."
apt-get update
apt-get upgrade -y

echo "Installing Java 17, PostgreSQL, Maven, Ant, Git..."
apt-get install -y \
    openjdk-17-jdk \
    postgresql \
    postgresql-contrib \
    maven \
    ant \
    git \
    curl \
    wget \
    unzip

echo "=== STEP 2: Setting up Java Environment ==="
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

# Make JAVA_HOME persistent
echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> /etc/environment
echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> /etc/environment

echo "Java version:"
java -version

echo "=== STEP 3: Creating DSpace System User ==="
if ! id "$DSPACE_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DSPACE_USER"
    echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> /home/$DSPACE_USER/.bashrc
    echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> /home/$DSPACE_USER/.bashrc
    echo "Created user: $DSPACE_USER"
else
    echo "User $DSPACE_USER already exists"
fi

echo "=== STEP 4: Setting up PostgreSQL Database ==="

# Create database user
sudo -u postgres psql -c "SELECT 1 FROM pg_user WHERE usename = '$DB_USER'" | grep -q 1 || \
sudo -u postgres psql <<EOF
CREATE USER $DB_USER WITH PASSWORD '$DB_PASS' NOSUPERUSER;
EOF

# Create database
sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 || \
sudo -u postgres psql <<EOF
CREATE DATABASE $DB_NAME WITH OWNER $DB_USER ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

# Enable pgcrypto extension
sudo -u postgres psql -d "$DB_NAME" <<EOF
CREATE EXTENSION IF NOT EXISTS pgcrypto;
EOF

# Configure PostgreSQL for TCP/IP connections
PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version()" | grep -oP '(?<=PostgreSQL )\d+')
PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"

# Enable listen on localhost
if ! grep -q "^listen_addresses = 'localhost'" "$PG_CONF"; then
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" "$PG_CONF"
fi

# Add MD5 authentication for dspace database
if ! grep -q "host.*$DB_NAME.*$DB_USER" "$PG_HBA"; then
    sed -i "/^# TYPE.*DATABASE.*USER.*ADDRESS.*METHOD/a host    $DB_NAME    $DB_USER    127.0.0.1/32    md5" "$PG_HBA"
fi

systemctl restart postgresql

echo "Testing database connection..."
PGPASSWORD=$DB_PASS psql -h localhost -U $DB_USER -d $DB_NAME -c "SELECT version();" || {
    echo "ERROR: Database connection failed!"
    exit 1
}

echo "=== STEP 5: Installing Apache Solr ==="
cd /opt

if [ ! -d "$SOLR_DIR" ]; then
    echo "Downloading Solr ${SOLR_VERSION}..."
    wget "https://archive.apache.org/dist/solr/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz"
    tar xzf "solr-${SOLR_VERSION}.tgz"
    mv "solr-${SOLR_VERSION}" "$SOLR_DIR"
    rm "solr-${SOLR_VERSION}.tgz"
    
    # Create solr user if needed
    if ! id "solr" &>/dev/null; then
        useradd -r -s /bin/bash solr
    fi
    
    chown -R solr:solr "$SOLR_DIR"
else
    echo "Solr already exists at $SOLR_DIR"
fi

echo "=== STEP 6: Downloading DSpace Backend Source Code ==="
mkdir -p "$DSPACE_SRC"
cd /opt

if [ ! -d "$DSPACE_SRC/.git" ]; then
    echo "Cloning DSpace repository..."
    git clone https://github.com/DSpace/DSpace.git "$DSPACE_SRC"
    cd "$DSPACE_SRC"
    git checkout "dspace-${DSPACE_VERSION}"
else
    echo "DSpace source already exists at $DSPACE_SRC"
    cd "$DSPACE_SRC"
fi

chown -R "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_SRC"

echo "=== STEP 7: Configuring DSpace (local.cfg) ==="
cd "$DSPACE_SRC"

# Create local.cfg based on the official example
cat > "$DSPACE_SRC/local.cfg" <<EOF
# DSpace Installation Directory
dspace.dir = $DSPACE_DIR

# DSpace Hostname and URLs
dspace.hostname = localhost
dspace.server.url = http://localhost:8080/server
dspace.ui.url = http://localhost:4000

# Database Configuration
db.url = jdbc:postgresql://localhost:5432/$DB_NAME
db.username = $DB_USER
db.password = $DB_PASS
db.dialect = org.hibernate.dialect.PostgreSQLDialect
db.driver = org.postgresql.Driver
db.maxconnections = 30
db.maxwait = 5000
db.maxidle = -1
db.statementpool = true

# Solr Configuration  
solr.server = http://localhost:8983/solr

# Email Configuration (update for production!)
mail.server = localhost
mail.from.address = dspace-noreply@localhost
mail.admin = admin@localhost

# Default Language
default.language = en

# Handle prefix (use your own in production!)
handle.prefix = 123456789
EOF

echo "=== STEP 8: Creating DSpace Installation Directory ==="
mkdir -p "$DSPACE_DIR"
chown "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_DIR"

echo "=== STEP 9: Building DSpace Backend ==="
cd "$DSPACE_SRC"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

echo "This may take 10-20 minutes..."
sudo -u "$DSPACE_USER" bash -c "cd $DSPACE_SRC && export JAVA_HOME=$JAVA_HOME && export PATH=$JAVA_HOME/bin:\$PATH && mvn -U clean package"

echo "=== STEP 10: Installing DSpace Backend ==="
cd "$DSPACE_SRC/dspace/target/dspace-installer"
sudo -u "$DSPACE_USER" bash -c "cd $DSPACE_SRC/dspace/target/dspace-installer && ant fresh_install"

echo "=== STEP 11: Initializing Database ==="
sudo -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" database migrate

# Verify database
sudo -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" database info

echo "=== STEP 12: Installing Solr Cores ==="
# Start Solr if not running
if ! pgrep -f "start.jar" > /dev/null; then
    sudo -u solr "$SOLR_DIR/bin/solr" start
fi

# Wait for Solr to start
sleep 10

# Copy DSpace Solr cores
echo "Copying Solr cores..."
mkdir -p "$SOLR_DIR/server/solr/configsets"
cp -r "$DSPACE_DIR/solr/"* "$SOLR_DIR/server/solr/configsets/"
chown -R solr:solr "$SOLR_DIR/server/solr/configsets"

# Restart Solr to pick up new cores
sudo -u solr "$SOLR_DIR/bin/solr" restart

# Give Solr time to initialize cores
sleep 15

echo "=== STEP 13: Creating DSpace Administrator Account ==="
echo "Creating admin user..."
echo -e "admin@localhost\nAdmin\nUser\nadmin\nadmin" | sudo -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" create-administrator

echo "=== STEP 14: Starting DSpace Backend ==="

# Create systemd service for backend
cat > /etc/systemd/system/dspace-backend.service <<EOF
[Unit]
Description=DSpace Backend (REST API)
After=postgresql.service network.target

[Service]
Type=simple
User=$DSPACE_USER
Group=$DSPACE_USER
Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
Environment="PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
WorkingDirectory=$DSPACE_DIR/webapps
ExecStart=/usr/bin/java -jar $DSPACE_DIR/webapps/server-boot.jar --dspace.dir=$DSPACE_DIR
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dspace-backend
systemctl start dspace-backend

echo "Waiting for backend to start (may take 2-3 minutes)..."
for i in {1..60}; do
    if curl -s http://localhost:8080/server/api > /dev/null 2>&1; then
        echo "Backend is running!"
        break
    fi
    echo -n "."
    sleep 3
done
echo ""

# ==========================================
# FRONTEND INSTALLATION
# ==========================================

echo ""
echo "=== STEP 15: Installing Frontend Prerequisites ==="

# Install Node.js 20.x (LTS)
echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

echo "Node version:"
node --version
npm --version

# Install PM2 globally
npm install -g pm2 yarn

echo "=== STEP 16: Downloading DSpace Frontend Source Code ==="
cd /opt

if [ ! -d "$DSPACE_UI/.git" ]; then
    echo "Cloning DSpace Angular repository..."
    git clone https://github.com/DSpace/dspace-angular.git "$DSPACE_UI"
    cd "$DSPACE_UI"
    git checkout "dspace-${DSPACE_VERSION}"
else
    echo "DSpace Angular already exists at $DSPACE_UI"
    cd "$DSPACE_UI"
fi

echo "=== STEP 17: Installing Frontend Dependencies ==="
cd "$DSPACE_UI"
npm install

echo "=== STEP 18: Configuring Frontend ==="
# Create production config
cat > "$DSPACE_UI/config/config.prod.yml" <<EOF
# User Interface (UI) Configuration
ui:
  ssl: false
  host: localhost
  port: 4000
  nameSpace: /

# REST API Configuration
rest:
  ssl: false
  host: localhost
  port: 8080
  nameSpace: /server
EOF

echo "=== STEP 19: Building Frontend ==="
echo "This may take 10-15 minutes..."
npm run build:prod

echo "=== STEP 20: Setting Up Frontend for Production ==="
# Change ownership
chown -R "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_UI"

# Create PM2 configuration
cat > "$DSPACE_UI/dspace-ui.json" <<EOF
{
  "apps": [
    {
      "name": "dspace-ui",
      "cwd": "$DSPACE_UI",
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

chown "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_UI/dspace-ui.json"

# Create systemd service for frontend
cat > /etc/systemd/system/dspace-frontend.service <<EOF
[Unit]
Description=DSpace Frontend (Angular UI)
After=network.target dspace-backend.service

[Service]
Type=forking
User=$DSPACE_USER
Group=$DSPACE_USER
WorkingDirectory=$DSPACE_UI
ExecStart=/usr/bin/pm2 start $DSPACE_UI/dspace-ui.json
ExecStop=/usr/bin/pm2 stop dspace-ui
ExecReload=/usr/bin/pm2 reload dspace-ui
Restart=on-failure
RestartSec=10
Environment=NODE_ENV=production
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dspace-frontend

echo "=== STEP 21: Starting Frontend ==="
# Start PM2 as dspace user
sudo -u "$DSPACE_USER" pm2 start "$DSPACE_UI/dspace-ui.json"

# Save PM2 process list
sudo -u "$DSPACE_USER" pm2 save

# Setup PM2 startup script
pm2 startup systemd -u "$DSPACE_USER" --hp /home/"$DSPACE_USER"

sleep 10

# ==========================================
# VERIFICATION & COMPLETION
# ==========================================

echo ""
echo "=== Installation Verification ==="
echo ""

echo "Backend status:"
systemctl status dspace-backend --no-pager || true
echo ""

echo "Frontend status:"
sudo -u "$DSPACE_USER" pm2 status
echo ""

echo "Checking backend accessibility..."
curl -s http://localhost:8080/server/api | head -n 5 || echo "Backend not responding yet"
echo ""

echo "Checking frontend accessibility..."
curl -s http://localhost:4000 | head -n 5 || echo "Frontend not responding yet"
echo ""

echo "=== Installation Complete! ==="
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DSPACE ${DSPACE_VERSION} INSTALLATION SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📂 Installation Directories:"
echo "   Backend:  $DSPACE_DIR"
echo "   Source:   $DSPACE_SRC"
echo "   Frontend: $DSPACE_UI"
echo "   Solr:     $SOLR_DIR"
echo ""
echo "🗄️  Database:"
echo "   Database:  $DB_NAME"
echo "   User:      $DB_USER"
echo "   Password:  $DB_PASS"
echo ""
echo "🌐 Access URLs:"
echo "   Frontend UI:  http://localhost:4000"
echo "   Backend API:  http://localhost:8080/server"
echo "   Solr Admin:   http://localhost:8983/solr"
echo ""
echo "👤 Admin Account:"
echo "   Email:    admin@localhost"
echo "   Password: admin"
echo ""
echo "🔧 Service Management:"
echo "   Backend:"
echo "     sudo systemctl {start|stop|restart|status} dspace-backend"
echo "     sudo journalctl -u dspace-backend -f"
echo ""
echo "   Frontend:"
echo "     sudo -u $DSPACE_USER pm2 {start|stop|restart|status|logs} dspace-ui"
echo "     sudo journalctl -u dspace-frontend -f"
echo ""
echo "   Solr:"
echo "     sudo -u solr $SOLR_DIR/bin/solr {start|stop|restart|status}"
echo ""
echo "🔒 Security Reminders:"
echo "   ⚠️  CHANGE the database password in $DSPACE_SRC/local.cfg"
echo "   ⚠️  CHANGE the admin password via the UI"
echo "   ⚠️  UPDATE handle.prefix in local.cfg (get one from handle.net)"
echo "   ⚠️  CONFIGURE email settings in local.cfg"
echo "   ⚠️  ENABLE HTTPS for production (required for login to work!)"
echo ""
echo "📚 Documentation:"
echo "   https://wiki.lyrasis.org/display/DSDOC9x"
echo ""
echo "✅ Both services will auto-start on system boot!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
