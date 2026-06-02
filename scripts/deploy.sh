#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────
# TransporteZC — Deploy script for nginx
# Usage:
#   bash scripts/deploy.sh <domain> <ssh_user> <server_ip> [pem_file]
# ──────────────────────────────────────────────────────────────────

DOMAIN="${1:?Usage: bash scripts/deploy.sh <domain> <ssh_user> <server_ip> [pem_file]}"
SSH_USER="${2:?Missing ssh_user}"
SERVER_IP="${3:?Missing server_ip}"
PEM_FILE="${4:-}"

REMOTE_PATH="/var/www/transportezcadmin"
LOCAL_DIST="dist"
NGINX_SITES="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
CONF_NAME="transportransportezcadmintezc"
CONF_REMOTE="$NGINX_SITES/$CONF_NAME.conf"

# ── SSL certificate directory ────────────────────────────────────
# Set this to the directory containing fullchain.pem, privkey.pem, chain.pem.
# Leave empty to generate an HTTP-only config (no SSL).
# Example: SSL_CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
#SSL_CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
SSL_CERT_DIR=""
# ─────────────────────────────────────────────────────────────────

# ── SSH setup ──────────────────────────────────────────────────
SSH_OPTS=""
RSYNC_SSH="ssh"
if [ -n "$PEM_FILE" ]; then
    SSH_OPTS="-i $PEM_FILE"
    RSYNC_SSH="ssh -i $PEM_FILE"
fi
SSH_DEST="$SSH_USER@$SERVER_IP"

remote() { ssh $SSH_OPTS "$SSH_DEST" "$*"; }
remote_tee() { ssh $SSH_OPTS "$SSH_DEST" "cat > $1"; }

checksum_cmd() {
  if command -v md5sum &>/dev/null; then echo "md5sum"
  elif command -v md5 &>/dev/null; then echo "md5"
  else echo "shasum -a 256"
  fi
}

# ── Build ─────────────────────────────────────────────────────
echo "→ Building project…"
npm run build

echo "→ Ensuring remote directory exists…"
remote "mkdir -p $REMOTE_PATH"

echo "→ Uploading dist files…"
rsync -avz --delete -e "$RSYNC_SSH" "$LOCAL_DIST/" "$SSH_DEST:$REMOTE_PATH/"

# ── Render nginx config ──────────────────────────────────────
TMP_CONF=$(mktemp)
trap 'rm -f "$TMP_CONF"' EXIT

BUILTIN="
    root $REMOTE_PATH;
    index index.html;

    add_header X-Content-Type-Options    'nosniff' always;
    add_header X-Frame-Options           'DENY' always;
    add_header X-XSS-Protection          '1; mode=block' always;
    add_header Referrer-Policy           'strict-origin-when-cross-origin' always;
    add_header Permissions-Policy        'camera=(self), microphone=(), geolocation=(), payment=(), usb=(), magnetometer=(), accelerometer=()' always;

    add_header Content-Security-Policy \"default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com data:; img-src 'self' data: blob: https://*.supabase.co; connect-src 'self' https://*.supabase.co https://ve.dolarapi.com wss://*.supabase.co; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'self';\" always;

    server_tokens off;
    client_max_body_size 10M;

    location / {
        try_files \$uri \$uri/ /index.html;
        location = /index.html {
            add_header Cache-Control 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0' always;
            expires off;
        }
    }

    location /assets/ {
        expires 1y;
        add_header Cache-Control 'public, immutable, max-age=31536000';
        access_log off;
    }

    location ~* \\.(ico|webp|png|svg|pdf)\$ {
        expires 30d;
        add_header Cache-Control 'public, max-age=2592000';
        access_log off;
    }

    location ~* \\.(env|json|yml|yaml|md|log|bak|sql|sh|lock)\$ {
        deny all;
        return 404;
    }

    location ~ /\\. { deny all; return 404; }

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 256;
    gzip_types
        text/plain text/css text/javascript
        application/javascript application/json
        application/xml image/svg+xml
        font/woff font/woff2;

    access_log /var/log/nginx/\$host-access.log;
    error_log  /var/log/nginx/\$host-error.log warn;
"

SSL_BLOCK="
    ssl_certificate     $SSL_CERT_DIR/fullchain.pem;
    ssl_certificate_key $SSL_CERT_DIR/privkey.pem;
    ssl_trusted_certificate $SSL_CERT_DIR/chain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    add_header Strict-Transport-Security 'max-age=63072000; includeSubDomains; preload' always;
"

# ── Build site config ────────────────────────────────────────
{
    echo "# ================================================================"
    echo "# TransporteZC — nginx site configuration (hardened)"
    echo "# ================================================================"

    if [ -n "$SSL_CERT_DIR" ]; then
        # HTTP → HTTPS redirect
        echo "server {"
        echo "    listen 80;"
        echo "    listen [::]:80;"
        echo "    server_name $DOMAIN;"
        echo "    return 301 https://\$host\$request_uri;"
        echo "}"
        echo ""

        # HTTPS server
        echo "server {"
        echo "    listen 443 ssl http2;"
        echo "    listen [::]:443 ssl http2;"
        echo "    server_name $DOMAIN;"
        echo "$SSL_BLOCK"
        echo "$BUILTIN"
        echo "}"
    else
        # HTTP-only
        echo "server {"
        echo "    listen 80;"
        echo "    listen [::]:80;"
        echo "    server_name $DOMAIN;"
        echo "$BUILTIN"
        echo "}"
    fi
} > "$TMP_CONF"

echo "→ Generated nginx config ($([ -n "$SSL_CERT_DIR" ] && echo 'with SSL' || echo 'HTTP-only'))"

# ── Compute checksum ─────────────────────────────────────────
CKSUM_CMD=$(checksum_cmd)
NEW_CKSUM=$($CKSUM_CMD < "$TMP_CONF" | awk '{print $1}')

# ── Write config on server (atomic) ──────────────────────────
CONFIG_CHANGED=false
if remote "test -f $CONF_REMOTE" 2>/dev/null; then
    REMOTE_CKSUM=$(remote "$CKSUM_CMD < $CONF_REMOTE" | awk '{print $1}')
    if [ "$NEW_CKSUM" != "$REMOTE_CKSUM" ]; then
        echo "→ nginx config changed, updating…"
        CONFIG_CHANGED=true
    else
        echo "→ nginx config unchanged, skipping…"
    fi
else
    echo "→ nginx config does not exist, creating…"
    CONFIG_CHANGED=true
fi

if [ "$CONFIG_CHANGED" = true ]; then
    remote_tee "$CONF_REMOTE" < "$TMP_CONF"
    remote "ln -sf $CONF_REMOTE $NGINX_ENABLED/$CONF_NAME.conf"

    echo "→ Testing nginx configuration…"
    if remote "nginx -t 2>&1"; then
        echo "→ Reloading nginx…"
        remote "systemctl reload nginx 2>/dev/null || nginx -s reload"
    else
        echo "✗ nginx config test FAILED — check manually" >&2
        exit 1
    fi
fi

# ── Check if SSL certs actually exist on server ──────────────
if [ -n "$SSL_CERT_DIR" ]; then
    if ! remote "test -f $SSL_CERT_DIR/fullchain.pem" 2>/dev/null; then
        echo ""
        echo "⚠  SSL certificates not found in $SSL_CERT_DIR"
        echo "   Run on the server to obtain them:"
        echo ""
        echo "   certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN"
    fi
fi

echo ""
echo "✓ Deploy complete → $([ -n "$SSL_CERT_DIR" ] && echo 'https' || echo 'http')://$DOMAIN"
