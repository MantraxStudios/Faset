# Publicar la web en faset.lat

La web es estática (`npm run build` → `out/`). `start.sh` la compila y la sirve en
`127.0.0.1:8871` con `deploy/serve.mjs` (Node, sin dependencias), y nginx la publica en
`https://faset.lat` con un certificado de Let's Encrypt.

## Servidor actual

La web está publicada en `rhythm@192.168.1.57`, en `~/Escritorio/Faset` (junto a SRServi):

- servicio systemd `faset-web` → `docs/start.sh --no-build` en `127.0.0.1:8871`;
- nginx: `/etc/nginx/sites-available/faset.lat` (copia de `deploy/nginx/faset.lat.conf`);
- certificado de Let's Encrypt en `/etc/letsencrypt/live/faset.lat` (se renueva con `certbot.timer`);
- el dominio está detrás de Cloudflare (modo SSL *Full*): Cloudflare se conecta al servidor por HTTPS.

Actualizar:

```bash
cd ~/Escritorio/Faset && git pull && cd docs && ./start.sh --build-only && sudo systemctl restart faset-web
```

## 1. DNS

En el panel del dominio `faset.lat`, apunta el dominio a la IP pública del servidor:

| Tipo | Nombre | Valor |
|---|---|---|
| A | `@` | IP del servidor (IPv4) |
| A | `www` | la misma IP |
| AAAA | `@` y `www` | IPv6 del servidor (si tiene) |

Comprueba con `dig +short faset.lat` que ya devuelve la IP antes del paso 3 (certbot lo necesita).
El servidor debe aceptar conexiones en los puertos 80 y 443 (`sudo ufw allow 'Nginx Full'`).

## 2. Código en el servidor

```bash
git clone https://github.com/MantraxStudios/Faset.git
cd Faset/docs
```

## 3. Instalación (una vez)

```bash
sudo ./deploy/setup-server.sh --email tu@correo.com
```

Instala nginx, certbot, Node.js 22 y el compilador de C; activa `deploy/nginx/faset.lat.conf`;
compila la web; crea el servicio `faset-web` (systemd, puerto 8871, arranca con el servidor) y
pide el certificado HTTPS. Con `--no-ssl` se queda en http (por ejemplo, si el DNS aún no apunta).

## Uso diario

```bash
./start.sh                 # compilar y servir en 127.0.0.1:8871 (a mano, sin systemd)
./start.sh --no-build      # servir lo ya compilado
./start.sh --build-only    # solo compilar

# actualizar la web publicada
cd ~/Faset && git pull && cd docs && ./start.sh --build-only && sudo systemctl restart faset-web

journalctl -u faset-web -f          # registro del servidor de la web
sudo nginx -t && sudo systemctl reload nginx
```

`PORT` y `HOST` cambian el puerto y la interfaz (`PORT=9000 ./start.sh`). Si la web se publica en
otro dominio, compílala con `NEXT_PUBLIC_SITE_URL=https://otro.dominio`.

## Descargas

Los enlaces de descarga y `https://faset.lat/install.sh` / `install.ps1` bajan los paquetes de la
última versión de GitHub Releases (`faset-linux-x86_64.tar.gz`, `faset-windows-x86_64.zip`), que se
generan con `scripts/dist.sh` y se publican con
`gh release create v0.3.0 dist/faset-linux-x86_64.tar.gz dist/faset-windows-x86_64.zip`.
