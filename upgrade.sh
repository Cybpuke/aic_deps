#!/bin/bash

# OpenMetadata Upgrade Script
# Usage: sudo ./upgrade.sh <version>

set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [ -z "$1" ]; then
    echo "No version argument provided. Fetching latest version from GitHub..."
    # Fetch tag name, e.g., "1.2.0-release"
    LATEST_TAG=$(curl -s https://api.github.com/repos/open-metadata/OpenMetadata/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    
    if [ -z "$LATEST_TAG" ]; then
        echo "Error: Could not determine latest version from GitHub."
        echo "Please specify version manually: sudo $0 <version>"
        exit 1
    fi
    
    # Remove '-release' suffix if present to get version number (e.g., "1.2.0")
    VERSION=${LATEST_TAG%-release}
    echo "Latest version identified: ${VERSION}"
else
    VERSION=$1
fi
OM_user="openmetadata"
INSTALL_DIR="/opt/openmetadata"
CURRENT_LINK="${INSTALL_DIR}/current"
NEW_DIR="${INSTALL_DIR}/openmetadata-${VERSION}"


# Detect current version
if [ -L "${CURRENT_LINK}" ]; then
    CURRENT_PATH=$(readlink -f "${CURRENT_LINK}")
    CURRENT_INSTALLED_VERSION=$(basename "${CURRENT_PATH}" | sed 's/openmetadata-//')
    echo "Current OpenMetadata version detected: ${CURRENT_INSTALLED_VERSION}"
else
    echo "Current version: Unknown (symlink ${CURRENT_LINK} not found)"
fi

echo "Starting upgrade to OpenMetadata version ${VERSION}..."

# Pre-flight Check: Verify connectivity to dependencies
echo "Verifying network connectivity to dependencies..."

# Source existing config to get DB and ES hosts
if [ -f "${CURRENT_LINK}/conf/openmetadata.env" ]; then
    export $(grep -v '^#' "${CURRENT_LINK}/conf/openmetadata.env" | xargs)
    if [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ]; then
        echo "Error: details not found in configuration. Continuing but this is risky..."
    else
        echo "Checking connection to PostgreSQL at $DB_HOST:$DB_PORT..."
        if ! timeout 5 bash -c "</dev/tcp/$DB_HOST/$DB_PORT" 2>/dev/null; then
            echo "Error: Cannot connect to PostgreSQL at $DB_HOST:$DB_PORT. Aborting."
            exit 1
        fi
        echo "PostgreSQL is reachable."
    fi

    if [ -z "$ELASTICSEARCH_HOST" ] || [ -z "$ELASTICSEARCH_PORT" ]; then
        echo "Warning: Elasticsearch details not found."
    else
        echo "Checking connection to Elasticsearch at $ELASTICSEARCH_HOST:$ELASTICSEARCH_PORT..."
        if ! timeout 5 bash -c "</dev/tcp/$ELASTICSEARCH_HOST/$ELASTICSEARCH_PORT" 2>/dev/null; then
             echo "Error: Cannot connect to Elasticsearch at $ELASTICSEARCH_HOST:$ELASTICSEARCH_PORT. Aborting."
             exit 1
        fi
        echo "Elasticsearch is reachable."
    fi
else
    echo "Warning: No existing configuration found. Skipping connectivity checks."
fi




# 0. Backup (Recommended)
echo "----------------------------------------------------------------"
echo "Backup Check"
echo "----------------------------------------------------------------"
read -p "Do you want to backup the database before upgrading? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Preparing backup..."
    
    # Check for pg_dump
    if ! command -v pg_dump &> /dev/null; then
        echo "pg_dump not found. Installing postgresql client..."
        if [ -f /etc/redhat-release ]; then
            dnf install -y postgresql16
        elif [ -f /etc/debian_version ]; then
            apt-get update -qq && apt-get install -y postgresql-client
        else
            echo "Warning: Could not install pg_dump. Please install manually."
        fi
    fi

    # Source config safely to get DB credentials
    if [ -f "${CURRENT_LINK}/conf/openmetadata.env" ]; then
        # Use set -a in a subshell to capture variables without polluting current shell too much
        # But here we need them in current shell.
        set -a
        . "${CURRENT_LINK}/conf/openmetadata.env"
        set +a
    fi
    
    BACKUP_DIR="/opt/metadata-backup"
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/openmetadata_backup_${TIMESTAMP}.sql"
    
    echo "Target: $BACKUP_FILE"
    echo "Connecting to $DB_HOST:$DB_PORT as $DB_USER..."
    
    # Set password for pg_dump
    export PGPASSWORD="$DB_USER_PASSWORD"
    
    if pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$OM_DATABASE" -F c -f "$BACKUP_FILE"; then
        echo "Backup successful!"
        gzip "$BACKUP_FILE"
        echo "Backup compressed. Size: $(du -h ${BACKUP_FILE}.gz | cut -f1)"
        unset PGPASSWORD
    else
        echo "BACKUP FAILED!"
        unset PGPASSWORD
        echo "Possible reasons: Network issue, wrong password, or pg_dump version mismatch."
        read -p "Do you want to abort the upgrade? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        else
            echo "Proceeding without backup (AT YOUR OWN RISK)..."
        fi
    fi
else
    echo "Skipping backup."
fi

# 1. Stop Service

echo "Stopping OpenMetadata service..."
systemctl stop openmetadata


# 2. Download Release
echo "Downloading OpenMetadata ${VERSION}..."
wget -q "https://github.com/open-metadata/OpenMetadata/releases/download/${VERSION}-release/openmetadata-${VERSION}.tar.gz" -O "/tmp/openmetadata-${VERSION}.tar.gz"

# 3. Extract
echo "Extracting..."
tar -xzf "/tmp/openmetadata-${VERSION}.tar.gz" -C "${INSTALL_DIR}"

# 4. Copy Configuration
echo "Migrating configuration..."
if [ -d "${CURRENT_LINK}/conf" ]; then
    # Check if we are upgrading to the same version (source == dest)
    if [ "${CURRENT_LINK}/conf/openmetadata.env" -ef "${NEW_DIR}/conf/openmetadata.env" ]; then
        echo "Configuration files are the same (re-installing same version?). Skipping copy."
    else
        cp "${CURRENT_LINK}/conf/openmetadata.env" "${NEW_DIR}/conf/"
        # Copy keys if they exist
        if ls "${CURRENT_LINK}/conf/"*.der 1> /dev/null 2>&1; then
            cp "${CURRENT_LINK}/conf/"*.der "${NEW_DIR}/conf/"
        fi
    fi
else
    echo "Warning: No existing configuration found at ${CURRENT_LINK}/conf"
fi

# 5. Update Symlink
echo "Updating symlink..."
rm -f "${CURRENT_LINK}"
ln -s "${NEW_DIR}" "${CURRENT_LINK}"

# 6. Fix Ownership
echo "Setting ownership..."
chown -R ${OM_user}:${OM_user} "${INSTALL_DIR}"

# 7. Migrate Database
echo "Migrating database..."
# We need to run this as the openmetadata user to ensure file permissions of logs/etc are correct,
# and environment variables are handled correctly.
# The `set -a` is CRITICAL: it exports all variables from the .env file so the Java process sees them.
# Without this, it defaults to MySQL (localhost:3306) and fails with Connection Refused.
sudo -u ${OM_user} bash -c "cd ${CURRENT_LINK} && set -a && . conf/openmetadata.env && set +a && ./bootstrap/openmetadata-ops.sh migrate"

# 8. Start Service
echo "Starting OpenMetadata service..."
systemctl start openmetadata

# 9. Verify
echo "Waiting for service to start..."
# Simple wait loop
for i in {1..30}; do
    if curl -s http://localhost:8585/api/v1/system/version > /dev/null; then
        echo "OpenMetadata is up and running!"
        echo "----------------------------------------------------------------"
        echo "IMPORTANT POST-UPGRADE STEPS:"
        echo "1. REINDEXING: You MUST reindex your metadata."
        echo "   - Go to Settings -> Applications -> Search Indexing"
        echo "   - Click 'Run Now' with 'Recreate Indexes' enabled."
        echo "   - Alternatively, use the 'openmetadata-ops.sh reindex' command."
        echo ""
        echo "2. POSTGRESQL CONFIG: If you see 'Out of Sort Memory' errors,"
        echo "   please increase 'work_mem' to 20MB in your PostgreSQL configuration."
        echo "----------------------------------------------------------------"
        exit 0
    fi
    sleep 5
done

echo "Timeout waiting for OpenMetadata to start. Check logs: journalctl -u openmetadata"
exit 1
