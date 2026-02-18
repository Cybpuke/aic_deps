sudo dnf install -y unixODBC-devel
sudo curl -o /etc/yum.repos.d/msprod.repo https://packages.microsoft.com/config/rhel/9/prod.repo
sudo ACCEPT_EULA=Y dnf install -y msodbcsql18
sudo -u airflow /opt/airflow/venv/bin/pip install pyodbc
systemctl restart airflow-scheduler airflow-webserver
