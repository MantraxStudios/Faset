#!/usr/bin/env bash
# Prepara un servidor Linux (Debian/Ubuntu) para publicar la web en faset.lat:
#   1. instala nginx, certbot, Node.js (si falta) y lo necesario para compilar faset
#   2. instala la configuración de nginx (deploy/nginx/faset.lat.conf) y la activa
#   3. crea el servicio systemd 'faset-web' que ejecuta start.sh (puerto 8871) al arrancar
#   4. pide el certificado HTTPS con certbot (el dominio ya debe apuntar a este servidor)
#
# Uso (desde docs/):  sudo ./deploy/setup-server.sh [--email tu@correo] [--no-ssl]
set -euo pipefail
DOCS=$(cd "$(dirname "$0")/.." && pwd)
DOMAIN=faset.lat
EMAIL=""
SSL=1
while [ $# -gt 0 ]; do
    case "$1" in
        --email) EMAIL=$2; shift ;;
        --no-ssl) SSL=0 ;;
        *) echo "opción desconocida: $1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$(id -u)" -ne 0 ]; then
    echo "Ejecútalo con sudo: sudo $0 $*" >&2
    exit 1
fi
RUN_USER=${SUDO_USER:-$(stat -c %U "$DOCS")}

echo "== paquetes"
apt-get update
apt-get install -y nginx certbot python3-certbot-nginx build-essential g++ make curl
if ! command -v node > /dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
    echo "== Node.js 22 (NodeSource)"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
fi
NODE_BIN=$(command -v node)

echo "== nginx"
install -m644 "$DOCS/deploy/nginx/faset.lat.conf" /etc/nginx/sites-available/$DOMAIN
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "== compilación inicial de la web (como $RUN_USER)"
sudo -u "$RUN_USER" -H env PATH="$(dirname "$NODE_BIN"):/usr/local/bin:/usr/bin:/bin" "$DOCS/start.sh" --build-only

echo "== servicio systemd faset-web (puerto 8871)"
cat > /etc/systemd/system/faset-web.service <<UNIT
[Unit]
Description=Web de Faset (faset.lat) en el puerto 8871
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$DOCS
Environment=PORT=8871
Environment=HOST=127.0.0.1
Environment=PATH=$(dirname "$NODE_BIN"):/usr/local/bin:/usr/bin:/bin
ExecStart=$DOCS/start.sh --no-build
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now faset-web
systemctl restart faset-web

if [ "$SSL" -eq 1 ]; then
    echo "== HTTPS con Let's Encrypt"
    if [ -n "$EMAIL" ]; then
        certbot --nginx -d $DOMAIN -d www.$DOMAIN --redirect --agree-tos -m "$EMAIL" --non-interactive
    else
        certbot --nginx -d $DOMAIN -d www.$DOMAIN --redirect
    fi
fi

echo
echo "Listo: https://$DOMAIN"
echo "  Actualizar la web:  cd $DOCS/.. && git pull && cd docs && ./start.sh --build-only && sudo systemctl restart faset-web"
echo "  Registro:           journalctl -u faset-web -f"
