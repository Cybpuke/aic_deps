sudo -u airflow /opt/airflow/venv/bin/python -c "
import pyodbc
conn_str = (
    'DRIVER={ODBC Driver 18 for SQL Server};'
    'SERVER=10.10.25.106,1433;'
    'DATABASE=master;'
    'UID=DataOfficeUser;'
    'PWD=YOUR_ACTUAL_PASSWORD_HERE;'
    'Encrypt=no;'
    'TrustServerCertificate=yes;'
)
try:
    conn = pyodbc.connect(conn_str, timeout=10)
    print('SUCCESS! Connected to MSSQL')
    conn.close()
except Exception as e:
    print(f'FAILED: {e}')
"
