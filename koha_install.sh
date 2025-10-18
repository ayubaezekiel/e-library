#!/bin/bash

# Koha Library System Installation Script
# OPAC on port 8001, Staff interface on port 8000

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

echo "=== Updating system ==="
apt-get update
apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl

echo "=== Adding Koha repository ==="
mkdir -p --mode=0755 /etc/apt/keyrings
curl -fsSL https://debian.koha-community.org/koha/gpg.asc -o /etc/apt/keyrings/koha.asc

# Add Koha repository to sources
echo "deb [signed-by=/etc/apt/keyrings/koha.asc] https://debian.koha-community.org/koha stable main" | \
    tee /etc/apt/sources.list.d/koha.list

apt-get update

echo "=== Installing Koha and MariaDB ==="
apt-get install -y koha-common mariadb-server

echo "=== Configuring Apache modules ==="
a2enmod rewrite cgi headers proxy_http
# a2dissite 000-default  # Disable default site to avoid conflicts

echo "=== Configuring koha-sites.conf ==="
sed -i 's|INTRAPORT=".*"|INTRAPORT="8000"|' /etc/koha/koha-sites.conf
sed -i 's|OPACPORT=".*"|OPACPORT="8001"|' /etc/koha/koha-sites.conf

echo "=== Creating Koha instance: fuazlibrary ==="
koha-create --create-db fuazlibrary

echo "=== Enabling and starting Plack ==="
koha-plack --enable fuazlibrary
koha-plack --start fuazlibrary

echo "=== Configuring Apache ports ==="
# Backup original
cp /etc/apache2/ports.conf /etc/apache2/ports.conf.bak

# Remove default Listen 80 if present
# sed -i '/^Listen 80$/d' /etc/apache2/ports.conf

# Add our custom ports (check if already present)
grep -qxF 'Listen 8000' /etc/apache2/ports.conf || echo 'Listen 8000' >> /etc/apache2/ports.conf
grep -qxF 'Listen 8001' /etc/apache2/ports.conf || echo 'Listen 8001' >> /etc/apache2/ports.conf

echo "=== Restarting Apache ==="
systemctl restart apache2

echo "=== Retrieving Koha password ==="
echo ""
echo "Your Koha admin credentials:"
echo "Username: koha_fuazlibrary"
echo "Password: $(koha-passwd fuazlibrary)"
echo ""
echo "=== Installation complete! ==="
echo "Staff interface: http://localhost:8000"
echo "OPAC interface: http://localhost:8001"
echo ""
echo "Next steps:"
echo "1. Complete web installer at http://localhost:8000"
echo "2. Use the credentials shown above"