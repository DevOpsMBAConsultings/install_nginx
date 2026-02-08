#!/usr/bin/env bash
set -euo pipefail

echo "Installing and configuring Nginx + SSL for existing Odoo..."

# ------------------------------------------------------------
# Paths (project root = parent of scripts/)
# ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NGINX_TEMPLATE="${PROJECT_ROOT}/templates/nginx-odoo.conf.template"
NGINX_SSL_TEMPLATE="${PROJECT_ROOT}/templates/nginx-odoo-ssl.conf.template"
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

ODOO_PORT="${ODOO_PORT:-8069}"

# SSL store (local path). Remote storage is configured below (s3 or url).
SSL_STORE="${ODOO_SSL_STORE:-/opt/odoo/ssl-store}"
CERT_DIR="${SSL_STORE}/${DOMAIN}"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"

# Remote storage
SSL_STORAGE_TYPE="${ODOO_SSL_STORAGE:-}"
SSL_RESTORE_URL="${ODOO_SSL_RESTORE_URL:-}"
SSL_BACKUP_URL="${ODOO_SSL_BACKUP_URL:-}"
SSL_BACKUP_TOKEN="${ODOO_SSL_BACKUP_TOKEN:-}"
S3_BUCKET="${ODOO_SSL_S3_BUCKET:-}"
S3_PREFIX="${ODOO_SSL_S3_PREFIX:-odoo-ssl}"
S3_ENDPOINT="${ODOO_SSL_S3_ENDPOINT_URL:-${AWS_ENDPOINT_URL:-}}"

# ------------------------------------------------------------
# Required env vars
# ------------------------------------------------------------
if [[ -z "${DOMAIN:-}" ]]; then
  echo "ERROR: DOMAIN is missing."
  exit 1
fi

if [[ -z "${LETSENCRYPT_EMAIL:-}" ]]; then
  echo "ERROR: LETSENCRYPT_EMAIL is missing."
  exit 1
fi

if [[ ! -f "${NGINX_TEMPLATE}" ]]; then
  echo "ERROR: Missing template: ${NGINX_TEMPLATE}"
  exit 1
fi

# ------------------------------------------------------------
# Install packages
# ------------------------------------------------------------
apt-get update -y
apt-get install -y nginx certbot python3-certbot-nginx
if [[ "${SSL_STORAGE_TYPE}" == "s3" ]]; then
  if ! command -v aws >/dev/null 2>&1; then
    apt-get install -y awscli 2>/dev/null || true
  fi
  if ! command -v aws >/dev/null 2>&1; then
    echo "Installing AWS CLI v2 for S3/R2..."
    apt-get install -y curl unzip
    TMP_AWS="/tmp/awscliv2"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${TMP_AWS}.zip"
    unzip -o -q "${TMP_AWS}.zip" -d /tmp
    /tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin
    rm -rf "${TMP_AWS}.zip" /tmp/aws
  fi
fi

# ------------------------------------------------------------
# Restore from remote storage
# ------------------------------------------------------------
if [[ "${SSL_STORAGE_TYPE}" == "s3" && -n "${S3_BUCKET}" ]]; then
  if [[ ! -f "${FULLCHAIN}" || ! -f "${PRIVKEY}" ]]; then
    S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/${DOMAIN}/cert.tar.gz"
    echo "Trying to restore SSL certificate from ${S3_URI}..."
    mkdir -p "${CERT_DIR}"
    AWS_OPTS=()
    [[ -n "${S3_ENDPOINT}" ]] && AWS_OPTS+=(--endpoint-url "${S3_ENDPOINT}")
    if aws s3 cp "${S3_URI}" - "${AWS_OPTS[@]}" 2>/dev/null | tar -xzf - -C "${CERT_DIR}" 2>/dev/null; then
      if [[ -f "${FULLCHAIN}" && -f "${PRIVKEY}" ]]; then
        chmod 644 "${FULLCHAIN}"
        chmod 600 "${PRIVKEY}"
        echo "Restored certificate from S3 into ${CERT_DIR}"
      else
        rm -f "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" 2>/dev/null || true
      fi
    else
      echo "No certificate found in S3; will use Certbot if needed."
    fi
  fi
fi

if [[ -n "${SSL_RESTORE_URL}" ]]; then
  if [[ ! -f "${FULLCHAIN}" || ! -f "${PRIVKEY}" ]]; then
    echo "Restoring SSL certificate from ${SSL_RESTORE_URL}..."
    mkdir -p "${CERT_DIR}"
    if curl -fsSL --connect-timeout 30 "${SSL_RESTORE_URL}" | tar -xzf - -C "${CERT_DIR}" 2>/dev/null; then
      if [[ -f "${FULLCHAIN}" && -f "${PRIVKEY}" ]]; then
        chmod 644 "${FULLCHAIN}"
        chmod 600 "${PRIVKEY}"
        echo "Restored certificate into ${CERT_DIR}"
      else
        rm -f "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" 2>/dev/null || true
      fi
    else
      echo "⚠️ Failed to download or extract; will try Certbot if needed."
    fi
  fi
fi

# ------------------------------------------------------------
# Decide: use stored cert or request new one
# ------------------------------------------------------------
USE_STORED_CERT=0
if [[ -f "${FULLCHAIN}" && -f "${PRIVKEY}" ]]; then
  if openssl x509 -noout -checkend 86400 -in "${FULLCHAIN}" 2>/dev/null; then
    echo "Using existing SSL certificate from ${CERT_DIR}"
    USE_STORED_CERT=1
  else
    echo "Stored cert expired or invalid; will request new one."
  fi
fi

# ------------------------------------------------------------
# Render Nginx site config
# ------------------------------------------------------------
if [[ "${USE_STORED_CERT}" -eq 1 ]]; then
  [[ -f "${NGINX_SSL_TEMPLATE}" ]] || { echo "ERROR: Missing template: ${NGINX_SSL_TEMPLATE}"; exit 1; }
  sed \
    -e "s|{{DOMAIN}}|${DOMAIN}|g" \
    -e "s|{{ODOO_PORT}}|${ODOO_PORT}|g" \
    -e "s|{{SSL_CERT_PATH}}|${FULLCHAIN}|g" \
    -e "s|{{SSL_KEY_PATH}}|${PRIVKEY}|g" \
    "${NGINX_SSL_TEMPLATE}" > "${NGINX_SITE}"
else
  sed \
    -e "s|{{DOMAIN}}|${DOMAIN}|g" \
    -e "s|{{ODOO_PORT}}|${ODOO_PORT}|g" \
    "${NGINX_TEMPLATE}" > "${NGINX_SITE}"
fi

ln -sf "${NGINX_SITE}" "${NGINX_ENABLED}"
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl enable --now nginx
systemctl reload nginx

if [[ "${USE_STORED_CERT}" -eq 1 ]]; then
  echo "✅ Nginx + SSL (from store) completed for ${DOMAIN}"
  exit 0
fi

# ------------------------------------------------------------
# Firewall / networking before Certbot
# ------------------------------------------------------------
echo "Stabilizing firewall / networking before Certbot..."
if ! command -v ufw >/dev/null 2>&1; then
  apt-get install -y ufw
fi
ufw allow 80 || true
ufw allow 443 || true
systemctl stop ufw || true
iptables -F
iptables -X
ip6tables -F || true
ip6tables -X || true
systemctl start ufw || true
sleep 5

# ------------------------------------------------------------
# Request cert with Certbot; on success, save and backup
# ------------------------------------------------------------
CERTBOT_OK=0
REACHABLE=0
LOCALHOST_FALLBACK=0
if curl -fsS --connect-timeout 5 "http://${DOMAIN}" >/dev/null; then
  REACHABLE=1
fi
# If curl to domain timed out (e.g. hairpin NAT), check if Nginx answers locally
if [[ "${REACHABLE}" -eq 0 ]] && curl -fsS --connect-timeout 2 -H "Host: ${DOMAIN}" "http://127.0.0.1/" >/dev/null; then
  echo "Domain not reachable from this host (e.g. cloud NAT); Nginx answers locally. Proceeding with Certbot (Let's Encrypt will connect from the internet)..."
  REACHABLE=1
  LOCALHOST_FALLBACK=1
fi
if [[ "${REACHABLE}" -eq 1 ]]; then
  [[ "${LOCALHOST_FALLBACK}" -eq 0 ]] && echo "Domain reachable over HTTP. Proceeding with Certbot..."
  if certbot --nginx \
    -d "${DOMAIN}" \
    -m "${LETSENCRYPT_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --redirect; then
    CERTBOT_OK=1
  else
    echo "⚠️ Certbot failed. Nginx remains on HTTP only."
  fi
else
  echo "⚠️ WARNING: ${DOMAIN} not reachable over HTTP. Skipping Certbot."
fi

if [[ "${CERTBOT_OK}" -eq 1 ]]; then
  LETSENCRYPT_LIVE="/etc/letsencrypt/live/${DOMAIN}"
  if [[ -d "${LETSENCRYPT_LIVE}" ]]; then
    echo "Saving certificate copy to ${CERT_DIR}..."
    mkdir -p "${CERT_DIR}"
    cp -p "${LETSENCRYPT_LIVE}/fullchain.pem" "${FULLCHAIN}"
    cp -p "${LETSENCRYPT_LIVE}/privkey.pem" "${PRIVKEY}"
    chmod 644 "${FULLCHAIN}"
    chmod 600 "${PRIVKEY}"
    ODOO_SSL_TARBALL="/tmp/odoo-ssl-${DOMAIN}.tar.gz"
    ( cd "${CERT_DIR}" && tar czf "${ODOO_SSL_TARBALL}" fullchain.pem privkey.pem )
    if [[ "${SSL_STORAGE_TYPE}" == "s3" && -n "${S3_BUCKET}" ]]; then
      S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/${DOMAIN}/cert.tar.gz"
      echo "Uploading certificate to ${S3_URI}..."
      AWS_OPTS=()
      [[ -n "${S3_ENDPOINT}" ]] && AWS_OPTS+=(--endpoint-url "${S3_ENDPOINT}")
      aws s3 cp "${ODOO_SSL_TARBALL}" "${S3_URI}" "${AWS_OPTS[@]}" && echo "Backup to S3 done." || echo "⚠️ S3 upload failed."
    fi
    if [[ -n "${SSL_BACKUP_URL}" ]]; then
      CURL_OPTS=(-fsSL -X PUT -T "${ODOO_SSL_TARBALL}" "${SSL_BACKUP_URL}")
      [[ -n "${SSL_BACKUP_TOKEN}" ]] && CURL_OPTS+=(-H "Authorization: Bearer ${SSL_BACKUP_TOKEN}")
      curl "${CURL_OPTS[@]}" && echo "Backup to URL done." || echo "⚠️ URL backup failed."
    fi
    rm -f "${ODOO_SSL_TARBALL}"
    sed \
      -e "s|{{DOMAIN}}|${DOMAIN}|g" \
      -e "s|{{ODOO_PORT}}|${ODOO_PORT}|g" \
      -e "s|{{SSL_CERT_PATH}}|${FULLCHAIN}|g" \
      -e "s|{{SSL_KEY_PATH}}|${PRIVKEY}|g" \
      "${NGINX_SSL_TEMPLATE}" > "${NGINX_SITE}"
    nginx -t
    systemctl reload nginx
  fi
fi

systemctl reload nginx
echo "✅ Nginx + SSL step completed for ${DOMAIN}"
