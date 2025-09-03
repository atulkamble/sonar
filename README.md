Awesome—let’s do **Option B** cleanly on **Amazon Linux 2023** for a single-VM setup:

* **EC2:** `t3.medium` (4 GB RAM) + **30–50 GB gp3**
* **SG inbound:** `22/tcp` (SSH), `9000/tcp` (SonarQube UI). Open `5432/tcp` only if you’ll connect to Postgres from outside.
* **Stack:** **Java 21**, **SonarQube (current)**, **PostgreSQL 17**, run SonarQube as a **systemd** service.

> Java 21 is supported by current SonarQube Server releases (2025). If you hit an edge-case on very old builds, drop to Java 17. ([docs.sonarsource.com][1])
> SonarQube supports PostgreSQL **13–17**. ([Sonar Community][2])

---

# 1) One-shot install script (Amazon Linux 2023)

> Save as `install-sonarqube-amzn2023.sh`, run with `sudo bash install-sonarqube-amzn2023.sh`.
> **You must provide a valid SonarQube ZIP URL** (from the official downloads page) via `SONAR_ZIP_URL=...`. Example shown in the comments. (The download URL changes per release.) ([sonarsource.com][3])

```bash
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
```

---

## 2) How to run

1. **Launch EC2** (Amazon Linux 2023, `t3.medium`, 30–50 GB gp3).
2. **Security Group**: allow `22/tcp`, `9000/tcp`. (Open `5432` only if external DB access is needed.)
3. **SSH in**, then:

```bash
# Example: set the official ZIP URL you copied from the downloads page:
export SONAR_ZIP_URL="https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-<CURRENT>.zip"
export PG_PASS='YourStrong#Password1'   # change me

curl -fsSL -o install-sonarqube-amzn2023.sh https://raw.githubusercontent.com/placeholder/sonar-install/main/install-amzn2023.sh
# or paste the script from above into a file
sudo bash install-sonarqube-amzn2023.sh
```

> To confirm service status & logs:

```bash
systemctl status sonarqube
journalctl -u sonarqube -e --no-pager
sudo -u sonarqube tail -n 200 /var/sonarqube/logs/{sonar,web,ce,es}.log
```

Then open: `http://<EC2_PUBLIC_IP>:9000` → login: `admin / admin` (force password change).

---

## 3) Notes & gotchas

* **Java 21 vs 17**: Current SonarQube builds support Java 21; if you’re installing an older build that complains, install **java-17-amazon-corretto** and point `wrapper.java.command` to it. ([docs.sonarsource.com][1])
* **Postgres 17**: Supported; if you ever upgrade SonarQube across major lines, re-check the “Supported DB versions” note in the release docs. ([Sonar Community][2])
* **Don’t run as root**: The unit runs as the unprivileged `sonarqube` user per SonarSource guidance. ([docs.sonarsource.com][4])
* **Kernel limits**: `vm.max_map_count=262144` is mandatory for the embedded Elasticsearch. The script persists it across reboots. (Common cause of startup failure.) ([docs.sonarsource.com][4])

---

If you want, I can also give you a **cloud-init** variant (paste into “User data” on launch) or a version that **binds Postgres on 0.0.0.0** with SSL and **moves SonarQube behind Nginx** on :80/:443.

[1]: https://docs.sonarsource.com/sonarqube-server/latest/server-upgrade-and-maintenance/release-notes/?utm_source=chatgpt.com "2025.4 release notes | SonarQube Server Documentation"
[2]: https://community.sonarsource.com/t/postgresql-support-in-release-upgrade-notes-for-2025-1-is-unclear-ambiguous/135078?utm_source=chatgpt.com "Postgresql support in release upgrade notes for 2025.1 is ..."
[3]: https://www.sonarsource.com/products/sonarqube/downloads/?utm_source=chatgpt.com "Download SonarQube"
[4]: https://docs.sonarsource.com/sonarqube-server/10.8/setup-and-upgrade/operating-the-server/?utm_source=chatgpt.com "Operating SonarQube Server | Documentation"
