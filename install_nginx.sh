#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "============================================================"
echo " Install Nginx + SSL for existing Odoo server"
echo " Project: ${SCRIPT_DIR}"
echo "============================================================"

# -------------------------------------------------------------------
# Prompts: domain, email, port, optional remote SSL storage
# -------------------------------------------------------------------

read -r -p "Domain name (e.g. erp.example.com): " DOMAIN
DOMAIN="${DOMAIN:-}"

read -r -p "Email for Let's Encrypt notifications: " LETSENCRYPT_EMAIL
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

read -r -p "Odoo port [8069]: " ODOO_PORT
ODOO_PORT="${ODOO_PORT:-8069}"

if [[ -z "${DOMAIN}" ]]; then
  echo "ERROR: DOMAIN is required."
  exit 1
fi

if [[ -z "${LETSENCRYPT_EMAIL}" ]]; then
  echo "ERROR: LETSENCRYPT_EMAIL is required."
  exit 1
fi

echo ""
echo "Remote SSL storage (optional): restore/backup certs from S3/R2 so you can reuse them on new servers."
read -r -p "Use remote SSL storage? (s3/url/no) [no]: " ODOO_SSL_STORAGE
ODOO_SSL_STORAGE="${ODOO_SSL_STORAGE:-no}"

if [[ "${ODOO_SSL_STORAGE}" == "s3" ]]; then
  read -r -p "S3/R2 bucket name [odoo-ssl-certs]: " ODOO_SSL_S3_BUCKET
  ODOO_SSL_S3_BUCKET="${ODOO_SSL_S3_BUCKET:-odoo-ssl-certs}"
  read -r -p "S3 endpoint URL (empty = AWS S3; for R2: https://ACCOUNT_ID.r2.cloudflarestorage.com): " ODOO_SSL_S3_ENDPOINT_URL
  read -r -p "Access Key ID: " AWS_ACCESS_KEY_ID
  read -s -r -p "Secret Access Key (hidden): " AWS_SECRET_ACCESS_KEY
  echo ""
  if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
    echo "Access Key and Secret are required for S3. Skipping remote storage."
    ODOO_SSL_STORAGE=""
  else
    export ODOO_SSL_S3_BUCKET
    export ODOO_SSL_S3_ENDPOINT_URL
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
  fi
elif [[ "${ODOO_SSL_STORAGE}" == "url" ]]; then
  read -r -p "Restore URL (GET .tar.gz): " ODOO_SSL_RESTORE_URL
  read -r -p "Backup URL (PUT .tar.gz, optional): " ODOO_SSL_BACKUP_URL
  read -r -p "Backup token (optional): " ODOO_SSL_BACKUP_TOKEN
  export ODOO_SSL_RESTORE_URL
  export ODOO_SSL_BACKUP_URL
  export ODOO_SSL_BACKUP_TOKEN
else
  ODOO_SSL_STORAGE=""
  unset ODOO_SSL_S3_BUCKET ODOO_SSL_S3_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY 2>/dev/null || true
  unset ODOO_SSL_RESTORE_URL ODOO_SSL_BACKUP_URL ODOO_SSL_BACKUP_TOKEN 2>/dev/null || true
fi

export ODOO_SSL_STORAGE
export DOMAIN
export LETSENCRYPT_EMAIL
export ODOO_PORT

# Optional: custom env names used by the ssl script
export ODOO_SSL_S3_PREFIX="${ODOO_SSL_S3_PREFIX:-odoo-ssl}"
export ODOO_SSL_S3_ENDPOINT_URL="${ODOO_SSL_S3_ENDPOINT_URL:-}"
export ODOO_SSL_RESTORE_URL="${ODOO_SSL_RESTORE_URL:-}"
export ODOO_SSL_BACKUP_URL="${ODOO_SSL_BACKUP_URL:-}"
export ODOO_SSL_BACKUP_TOKEN="${ODOO_SSL_BACKUP_TOKEN:-}"

# -------------------------------------------------------------------
# Run nginx + SSL install (requires sudo)
# -------------------------------------------------------------------

INSTALL_SCRIPT="${SCRIPT_DIR}/scripts/install_nginx_ssl.sh"
if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
  echo "ERROR: Missing script: ${INSTALL_SCRIPT}"
  exit 1
fi

chmod +x "${INSTALL_SCRIPT}"
echo ""
echo ">>> Installing Nginx + SSL for ${DOMAIN} (Odoo port ${ODOO_PORT})"
sudo -E bash "${INSTALL_SCRIPT}"

echo ""
echo "✅ Done. Nginx is configured for ${DOMAIN}."
