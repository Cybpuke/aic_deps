# === COMPLETE FIX: run this entire block on 10.10.25.44 ===

# Stop services
systemctl stop airflow-scheduler airflow-webserver

# 1. Install OS-level ODBC driver
apt-get update
apt-get install -y unixodbc unixodbc-dev curl gnupg
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg 2>/dev/null || true
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main" > /etc/apt/sources.list.d/mssql-release.list
apt-get update
ACCEPT_EULA=Y apt-get install -y msodbcsql18

# 2. Fix setuptools (77.0.3 is breaking ingestion)
sudo -u airflow /opt/airflow/venv/bin/pip install "setuptools==75.8.0" wheel

# 3. Install/reinstall pyodbc
sudo -u airflow /opt/airflow/venv/bin/pip install --force-reinstall pyodbc

# 4. Reinstall ingestion packages to fix any broken deps
OM_VER=$(sudo -u airflow /opt/airflow/venv/bin/pip show openmetadata-ingestion 2>/dev/null | grep "^Version:" | awk '{print $2}')
echo "OpenMetadata ingestion version: ${OM_VER}"
sudo -u airflow /opt/airflow/venv/bin/pip install --force-reinstall --no-cache-dir \
    "openmetadata-ingestion[all]==${OM_VER}" \
    "openmetadata-managed-apis==${OM_VER}"

# 5. Verify everything works
echo "=== VERIFICATION ==="
echo "ODBC Drivers:"
odbcinst -q -d
echo ""
echo "pyodbc:"
sudo -u airflow /opt/airflow/venv/bin/python -c "import pyodbc; print('version:', pyodbc.version); print('drivers:', pyodbc.drivers())"
echo ""
echo "setuptools:"
sudo -u airflow /opt/airflow/venv/bin/python -c "import setuptools; print('version:', setuptools.__version__)"
echo ""
echo "Network test to MSSQL:"
nc -zv 10.10.25.106 1433 2>&1

# 6. Restart services
systemctl start airflow-webserver airflow-scheduler
echo ""
echo "=== DONE. Retry the connection test in OpenMetadata UI ==="
