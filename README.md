# Install Nginx + SSL for existing Odoo servers

Standalone project to add **Nginx** and **HTTPS** to a server that already has Odoo running. No Odoo install, no database init—only Nginx, Certbot, and optional remote SSL storage (S3/R2 or URL).

Use this when:
- Odoo is already deployed (e.g. by [MBA-Odoo19-Community-install-process](https://github.com/your-org/MBA-Odoo19-Community-install-process)) and you need to add or re-add Nginx.
- You want the same flow: domain, Let's Encrypt email, optional remote SSL storage (S3/URL).

## Requirements

- Ubuntu (tested on 24.04).
- Odoo already running (e.g. on `127.0.0.1:8069`).
- Domain pointing to this server (for Certbot).
- Run as a user that can `sudo`.

## Quick start

1. Clone or copy this project to the server (e.g. under `~/install_nginx`).
2. Run the main script:

   ```bash
   cd install_nginx
   chmod +x install_nginx.sh
   ./install_nginx.sh
   ```

3. When prompted, enter:
   - **Domain name** (e.g. `erp.example.com`)
   - **Email** for Let's Encrypt
   - **Odoo port** (default `8069`)
   - **Remote SSL storage**: `s3`, `url`, or `no`

4. If you choose **s3** (e.g. Cloudflare R2):
   - Bucket name
   - S3 endpoint URL (for R2: `https://ACCOUNT_ID.r2.cloudflarestorage.com`)
   - Access Key ID and Secret Access Key

Certificates are stored locally under `/opt/odoo/ssl-store/<domain>/`. If you use S3/R2, the script will try to **restore** from `s3://<bucket>/odoo-ssl/<domain>/cert.tar.gz` and, after a new Certbot run, **backup** there so other servers can reuse the cert.

## Remote SSL storage

- **s3** – S3-compatible storage (AWS S3, Cloudflare R2, MinIO). Path: `odoo-ssl/<domain>/cert.tar.gz`.
- **url** – Restore from a GET URL; optionally backup to a PUT URL (with optional token).
- **no** – Only local store; no restore/backup.

See [MBA-Odoo19-Community-install-process docs](https://github.com/your-org/MBA-Odoo19-Community-install-process/tree/main/docs) (e.g. `SSL-STORAGE-CLOUDFLARE-R2.md`) for R2 setup; the same bucket layout and env vars apply here.

## Project layout

```
install_nginx/
├── install_nginx.sh          # Main entry: prompts, then runs script
├── scripts/
│   └── install_nginx_ssl.sh  # Nginx + Certbot + SSL store/S3/URL
├── templates/
│   ├── nginx-odoo.conf.template      # HTTP only
│   └── nginx-odoo-ssl.conf.template  # HTTPS with cert paths
├── config/
│   └── ssl-storage.env.example      # Optional env example
└── README.md
```

## Optional: run without prompts

Export variables and run the script directly (e.g. for automation):

```bash
export DOMAIN=erp.example.com
export LETSENCRYPT_EMAIL=admin@example.com
export ODOO_PORT=8069
export ODOO_SSL_STORAGE=s3
export ODOO_SSL_S3_BUCKET=my-bucket
export ODOO_SSL_S3_ENDPOINT_URL=https://ACCOUNT_ID.r2.cloudflarestorage.com
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
sudo -E ./scripts/install_nginx_ssl.sh
```

You must run `install_nginx_ssl.sh` from the project root (or set paths in the script); the script resolves `PROJECT_ROOT` as the parent of `scripts/`.
