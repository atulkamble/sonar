#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG (change as needed) ===========================================
SONAR_USER="sonarqube"
SONAR_GROUP="sonarqube"
SONAR_BASE="/opt/sonarqube"
SONAR_DATA="/var/sonarqube"
SONAR_PORT="9000"

# Get the ZIP URL from https://www.sonarsource.com/products/sonarqube/downloads/
# Example (replace with an actual current link):
# export SONAR_ZIP_URL="https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-<VERSION>.zip"
: "${SONAR_ZIP_URL:?Set SONAR_ZIP_URL to the official SonarQube ZIP URL}"

# DB settings
PG_VER="17"
PG_DB="sonarqube"
PG_USER="sonarqube"
: "${PG_PASS:=ChangeMeStrong!}"   # export PG_PASS before running, or it will use this default

# ====== PREP OS =============================================================
echo "[*] Updating OS & installing base packages..."
dnf -y update
dnf -y install unzip curl tar wget git jq net-tools

echo "[*] Install Java 21 (Amazon Corretto)..."
dnf -y install java-21-amazon-corretto-headless

echo "[*] Kernel & limits (required for Elasticsearch inside SonarQube)..."
sysctl -w vm.max_map_count=262144
sysctl -w fs.file-max=131072
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-sonarqube.conf
echo "fs.file-max=131072" >> /etc/sysctl.d/99-sonarqube.conf
sysctl --system >/dev/null

cat >/etc/security/limits.d/99-sonarqube.conf <<'LIMITS'
sonarqube   -   nofile   65536
sonarqube   -   nproc    4096
LIMITS

# ====== POSTGRESQL 17 =======================================================
echo "[*] Installing PostgreSQL ${PG_VER}..."
dnf -y install "postgresql${PG_VER}" "postgresql${PG_VER}-server"

echo "[*] Initializing PostgreSQL cluster..."
/usr/bin/postgresql-${PG_VER}-setup --initdb

echo "[*] Configure PostgreSQL to listen on localhost only..."
PGDATA="/var/lib/pgsql/${PG_VER}/data"
sed -i "s/^#\?listen_addresses.*/listen_addresses = '127.0.0.1'/" "${PGDATA}/postgresql.conf"

cat >>"${PGDATA}/pg_hba.conf" <<'HBA'
# Local connections
local   all             all                                     peer
# IPv4 local
host    all             all             127.0.0.1/32            md5
HBA

systemctl enable --now postgresql-${PG_VER}

echo "[*] Creating SonarQube DB & user..."
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_USER}') THEN
      CREATE ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASS}';
   END IF;
END
\$do\$;

CREATE DATABASE ${PG_DB} OWNER ${PG_USER};
GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};
SQL

# ====== SONARQUBE USER & DIRECTORIES =======================================
echo "[*] Creating ${SONAR_USER} user and directories..."
id -u ${SONAR_USER} &>/dev/null || useradd --system --create-home --home-dir "${SONAR_DATA}" --shell /sbin/nologin "${SONAR_USER}"

mkdir -p "${SONAR_BASE}" "${SONAR_DATA}/logs" "${SONAR_DATA}/temp" "${SONAR_DATA}/extensions"
chown -R ${SONAR_USER}:${SONAR_GROUP:-${SONAR_USER}} "${SONAR_BASE}" "${SONAR_DATA}"
usermod -a -G ${SONAR_USER} ${SONAR_USER} || true

# ====== DOWNLOAD & INSTALL SONARQUBE =======================================
echo "[*] Downloading SonarQube..."
cd /tmp
rm -f sonarqube.zip
curl -L "${SONAR_ZIP_URL}" -o sonarqube.zip

echo "[*] Unzipping to ${SONAR_BASE}..."
unzip -q sonarqube.zip
SQ_DIR="$(find . -maxdepth 1 -type d -name 'sonarqube*' | head -n1)"
test -n "${SQ_DIR}" || { echo "Could not find unzipped SonarQube directory"; exit 1; }
rsync -a "${SQ_DIR}/" "${SONAR_BASE}/"
chown -R ${SONAR_USER}:${SONAR_USER} "${SONAR_BASE}"

# Move data dirs out to /var/sonarqube for persistence
rm -rf "${SONAR_BASE}/data" "${SONAR_BASE}/logs" "${SONAR_BASE}/temp" "${SONAR_BASE}/extensions"
ln -s "${SONAR_DATA}/logs"       "${SONAR_BASE}/logs"
ln -s "${SONAR_DATA}/temp"       "${SONAR_BASE}/temp"
ln -s "${SONAR_DATA}/extensions" "${SONAR_BASE}/extensions"

# ====== SONARQUBE CONFIG ====================================================
echo "[*] Configuring sonar.properties..."
SONAR_PROP="${SONAR_BASE}/conf/sonar.properties"
cp "${SONAR_PROP}" "${SONAR_PROP}.bak.$(date +%s)"

# Minimal required settings
sed -i "s|^#sonar.web.port=.*|sonar.web.port=${SONAR_PORT}|" "${SONAR_PROP}"
sed -i "s|^#sonar.path.data=.*|sonar.path.data=${SONAR_DATA}|" "${SONAR_PROP}" || echo "sonar.path.data=${SONAR_DATA}" >> "${SONAR_PROP}"
sed -i "s|^#sonar.path.logs=.*|sonar.path.logs=${SONAR_DATA}/logs|" "${SONAR_PROP}" || echo "sonar.path.logs=${SONAR_DATA}/logs" >> "${SONAR_PROP}"

# DB config
grep -q '^sonar.jdbc.username=' "${SONAR_PROP}" || echo "sonar.jdbc.username=${PG_USER}" >> "${SONAR_PROP}"
grep -q '^sonar.jdbc.password=' "${SONAR_PROP}" || echo "sonar.jdbc.password=${PG_PASS}" >> "${SONAR_PROP}"
if grep -q '^#sonar.jdbc.url=jdbc:postgresql' "${SONAR_PROP}"; then
  sed -i "s|^#sonar.jdbc.url=jdbc:postgresql.*|sonar.jdbc.url=jdbc:postgresql://127.0.0.1:5432/${PG_DB}|" "${SONAR_PROP}"
else
  echo "sonar.jdbc.url=jdbc:postgresql://127.0.0.1:5432/${PG_DB}" >> "${SONAR_PROP}"
fi

# Java path (Amazon Corretto 21)
JAVA_HOME="$(dirname $(dirname $(readlink -f $(which java))))"
echo "wrapper.java.command=${JAVA_HOME}/bin/java" >> "${SONAR_BASE}/conf/wrapper.conf"

chown -R ${SONAR_USER}:${SONAR_USER} "${SONAR_BASE}" "${SONAR_DATA}"

# ====== SYSTEMD UNIT ========================================================
echo "[*] Creating systemd unit..."
cat >/etc/systemd/system/sonarqube.service <<UNIT
[Unit]
Description=SonarQube service
After=network.target postgresql-${PG_VER}.service
Wants=postgresql-${PG_VER}.service

[Service]
Type=forking
User=${SONAR_USER}
Group=${SONAR_USER}
LimitNOFILE=65536
LimitNPROC=4096
Environment=JAVA_HOME=${JAVA_HOME}
Environment=SONAR_HOME=${SONAR_BASE}
Environment=SONAR_JAVA_PATH=${JAVA_HOME}/bin/java
Environment=SONAR_LOG_DIR=${SONAR_DATA}/logs
ExecStart=${SONAR_BASE}/bin/linux-x86-64/sonar.sh start
ExecStop=${SONAR_BASE}/bin/linux-x86-64/sonar.sh stop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now sonarqube

echo "[*] Opening firewall (security group already allows 9000)..."
# If using firewalld on this host (off by default on AL2023), uncomment:
# firewall-cmd --permanent --add-port=${SONAR_PORT}/tcp && firewall-cmd --reload

echo
echo "==== INSTALL COMPLETE ===="
echo "URL:  http://<EC2_public_IP>:${SONAR_PORT}"
echo "First login: admin / admin (you'll be asked to change it)"
echo
echo "If SonarQube doesn't start, check:"
echo "  journalctl -u sonarqube -e --no-pager"
echo "  sudo -u ${SONAR_USER} tail -n 200 ${SONAR_DATA}/logs/{sonar,web,ce,es}.log"
