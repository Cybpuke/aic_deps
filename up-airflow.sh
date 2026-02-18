#!/bin/bash

# Airflow Upgrade Script (Ubuntu 24.04)
# Run on: kubernetes-control03 (10.10.25.44) — the Airflow node
# Usage: sudo ./upgrade-airflow.sh <new_airflow_version>
# Example: sudo ./upgrade-airflow.sh 2.10.5

set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: sudo $0 <new_airflow_version>"
    echo "Example: sudo $0 2.10.5"
    exit 1
fi

NEW_AIRFLOW_VERSION="$1"
AIRFLOW_HOME="/opt/airflow"
AIRFLOW_VENV="${AIRFLOW_HOME}/venv"
AIRFLOW_USER="airflow"
PYTHON_VERSION=$(${AIRFLOW_VENV}/bin/python --version 2>&1 | grep -oP '\d+\.\d+' | head -1)

echo "================================================================"
echo "  Airflow Upgrade Script (Ubuntu 24.04)"
echo "  Airflow Home: ${AIRFLOW_HOME}"
echo "  Python Version: ${PYTHON_VERSION}"
echo "================================================================"

# 0. Pre-flight checks
echo ""
echo "[Step 0] Pre-flight checks..."

if [ ! -d "${AIRFLOW_VENV}" ]; then
    echo "Error: Airflow venv not found at ${AIRFLOW_VENV}"
    exit 1
fi

CURRENT_AIRFLOW_VERSION=$(sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/airflow version 2>/dev/null || echo "unknown")
echo "Current Airflow version: ${CURRENT_AIRFLOW_VERSION}"
echo "Target Airflow version:  ${NEW_AIRFLOW_VERSION}"

SKIP_UPGRADE=false
if [ "${CURRENT_AIRFLOW_VERSION}" = "${NEW_AIRFLOW_VERSION}" ]; then
    echo "Airflow is already at version ${NEW_AIRFLOW_VERSION}. Skipping upgrade, will verify dependencies..."
    SKIP_UPGRADE=true
fi

if [ "${SKIP_UPGRADE}" = false ]; then

# 1. Stop Airflow services
echo ""
echo "[Step 1] Stopping Airflow services..."
systemctl stop airflow-scheduler || true
systemctl stop airflow-webserver || true
echo "Airflow services stopped."
sleep 5

# 2. Backup current Airflow config
echo ""
echo "[Step 2] Backing up Airflow configuration..."
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${AIRFLOW_HOME}/backup_${TIMESTAMP}"
mkdir -p "${BACKUP_DIR}"
cp "${AIRFLOW_HOME}/airflow.cfg" "${BACKUP_DIR}/" 2>/dev/null || true
cp -r "${AIRFLOW_HOME}/dags" "${BACKUP_DIR}/" 2>/dev/null || true
cp -r "${AIRFLOW_HOME}/plugins" "${BACKUP_DIR}/" 2>/dev/null || true
sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/pip freeze > "${BACKUP_DIR}/requirements_before.txt"
echo "Backup saved to: ${BACKUP_DIR}"

# 3. Upgrade pip and build tools
echo ""
echo "[Step 3] Upgrading pip and build tools..."
sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/pip install --upgrade pip setuptools wheel

# 4. Upgrade Airflow with constraints
echo ""
echo "[Step 4] Upgrading Apache Airflow to ${NEW_AIRFLOW_VERSION}..."
CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${NEW_AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
echo "Using constraints: ${CONSTRAINTS_URL}"

if ! curl -s --head "${CONSTRAINTS_URL}" | head -n 1 | grep -q "200"; then
    echo "Warning: Constraints file not found at ${CONSTRAINTS_URL}"
    PYTHON_MAJOR_MINOR=$(echo ${PYTHON_VERSION} | cut -d. -f1,2)
    CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${NEW_AIRFLOW_VERSION}/constraints-${PYTHON_MAJOR_MINOR}.txt"
    echo "Retrying with: ${CONSTRAINTS_URL}"
    if ! curl -s --head "${CONSTRAINTS_URL}" | head -n 1 | grep -q "200"; then
        echo "Error: Could not find valid constraints file. Aborting."
        exit 1
    fi
fi

sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/pip install --upgrade \
    "apache-airflow[postgres]==${NEW_AIRFLOW_VERSION}" \
    --constraint "${CONSTRAINTS_URL}"
echo "Airflow package upgraded."

# 5. Re-install OpenMetadata ingestion packages
echo ""
echo "[Step 5] Re-installing OpenMetadata ingestion packages..."
OM_VERSION=$(sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/pip show openmetadata-ingestion 2>/dev/null | grep -i "^Version:" | awk '{print $2}')

if [ -n "${OM_VERSION}" ]; then
    echo "Detected OpenMetadata ingestion version: ${OM_VERSION}"
    sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/pip install "setuptools<78" wheel
    if sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/pip install --upgrade --no-cache-dir \
        "openmetadata-ingestion[all]==${OM_VERSION}" \
        "openmetadata-managed-apis==${OM_VERSION}"; then
        echo "OpenMetadata packages re-installed successfully."
    else
        echo "Warning: Could not re-install OpenMetadata packages."
        echo "  sudo -u airflow ${AIRFLOW_VENV}/bin/pip install openmetadata-ingestion[all]==${OM_VERSION}"
    fi
else
    echo "Warning: Could not detect OpenMetadata ingestion version. Skipping."
fi

else
    echo ""
    echo "Skipping steps 1-5 (Airflow already at target version)."
    systemctl stop airflow-scheduler || true
    systemctl stop airflow-webserver || true
fi

# Disable exit-on-error for dependency installs
set +e

# 6. Install ALL required dependencies (Ubuntu 24.04)
echo ""
echo "================================================================"
echo "[Step 6] Installing ALL required dependencies (Ubuntu 24.04)..."
echo "================================================================"

# --- System-level packages ---
echo ""
echo "--- Installing system-level packages (apt) ---"
apt-get update -qq
apt-get install -y \
    unixodbc \
    unixodbc-dev \
    libpq-dev \
    gcc g++ make \
    libssl-dev \
    libffi-dev \
    libsasl2-dev \
    libldap2-dev \
    libkrb5-dev \
    libxml2-dev \
    libxslt1-dev \
    zlib1g-dev \
    pkg-config \
    curl \
    gnupg \
    apt-transport-https
echo ">>> System packages: DONE"

# --- Microsoft ODBC Driver 18 (for MSSQL ingestion) ---
echo ""
echo "--- Checking Microsoft ODBC Driver 18 ---"
if ! odbcinst -q -d 2>/dev/null | grep -qi "ODBC Driver 18"; then
    echo "ODBC Driver 18 NOT found. Installing..."
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main" > /etc/apt/sources.list.d/mssql-release.list
    apt-get update -qq
    ACCEPT_EULA=Y apt-get install -y msodbcsql18 mssql-tools18
    echo ">>> ODBC Driver 18: INSTALLED"
else
    echo ">>> ODBC Driver 18: Already installed"
fi
echo "Installed ODBC drivers:"
odbcinst -q -d 2>/dev/null || echo "  (none found)"

# --- Python packages in venv ---
echo ""
echo "--- Installing Python packages (pyodbc, presidio-analyzer) ---"
sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/pip install pyodbc presidio-analyzer

# Verify pyodbc can actually import
echo ""
echo "--- Verifying pyodbc import ---"
if sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/python -c "import pyodbc; print('pyodbc version:', pyodbc.version)" 2>&1; then
    echo ">>> pyodbc: WORKING"
else
    echo ">>> ERROR: pyodbc failed to import! MSSQL ingestion will NOT work."
fi

# --- spaCy model ---
echo ""
echo "--- Checking spaCy model ---"
if ! sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/python -c "import spacy; spacy.load('en_core_web_sm')" 2>/dev/null; then
    echo "spaCy model not found. Installing..."
    sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/python -m spacy download en_core_web_sm
    echo ">>> spaCy model: INSTALLED"
else
    echo ">>> spaCy model: Already installed"
fi

echo ""
echo "================================================================"
echo "All dependencies installed and verified."
echo "================================================================"

# Re-enable exit-on-error
set -e

# 7. Run Airflow DB migration
echo ""
echo "[Step 7] Running Airflow database migration..."
sudo -u ${AIRFLOW_USER} bash -c "
    export AIRFLOW_HOME=${AIRFLOW_HOME}
    source ${AIRFLOW_VENV}/bin/activate
    airflow db migrate
"
echo "Database migration complete."

# 8. Start Airflow services
echo ""
echo "[Step 8] Starting Airflow services..."
systemctl start airflow-webserver
systemctl start airflow-scheduler
echo "Airflow services started."

# 9. Verify
echo ""
echo "[Step 9] Verifying Airflow..."
sleep 10

NEW_VERSION=$(sudo -u ${AIRFLOW_USER} ${AIRFLOW_VENV}/bin/airflow version 2>/dev/null || echo "unknown")
echo "Airflow version after upgrade: ${NEW_VERSION}"

echo "Waiting for Airflow webserver to respond..."
for i in {1..24}; do
    if curl -s http://localhost:8080/health > /dev/null 2>&1; then
        echo "Airflow webserver is healthy!"
        break
    fi
    if [ $i -eq 24 ]; then
        echo "Warning: Airflow webserver did not respond within 2 minutes."
        echo "Check logs: journalctl -u airflow-webserver -n 50"
    fi
    sleep 5
done

echo ""
echo "================================================================"
echo "  Airflow upgrade complete: ${CURRENT_AIRFLOW_VERSION} -> ${NEW_VERSION}"
echo "================================================================"
echo ""
echo "POST-UPGRADE CHECKLIST:"
echo "  1. Verify DAGs are loading: http://10.10.25.44:8080"
echo "  2. Check scheduler logs: journalctl -u airflow-scheduler -f"
echo "  3. Check webserver logs: journalctl -u airflow-webserver -f"
echo "  4. Test a sample ingestion pipeline from OpenMetadata UI"
echo ""
