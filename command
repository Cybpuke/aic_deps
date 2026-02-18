# Fix setuptools to the version ingestion actually requires
sudo -u airflow /opt/airflow/venv/bin/pip install "setuptools~=78.1.1"

# Verify ODBC driver installed
odbcinst -q -d

# Verify pyodbc works
sudo -u airflow /opt/airflow/venv/bin/python -c "import pyodbc; print('version:', pyodbc.version); print('drivers:', pyodbc.drivers())"

# Test network to MSSQL
nc -zv 10.10.25.106 1433

# Restart Airflow
systemctl restart airflow-scheduler airflow-webserver
