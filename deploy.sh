#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] Stage ${stage:-inicio}, línea ${LINENO}. Despliegue detenido." >&2' ERR

usage() {
    echo "Uso: sudo bash deploy.sh DOMINIO EMAIL_ACME [--ibmi]"
    echo "Ejemplo: sudo bash deploy.sh motor.ejemplo.com admin@ejemplo.com"
    echo "Opcional: DOGCODE_REF=commit/rama/tag (por defecto: main). Ver README."
}
die() { echo "[ERROR] $*" >&2; exit 1; }
step() { stage="$1"; echo; echo "[STAGE $stage/7] $2"; }
health() {
    local url="$1"
    for _ in {1..20}; do
        if curl -fsS --max-time 2 "$url" 2>/dev/null |
            python3 -c 'import sys,json; sys.exit(json.load(sys.stdin).get("status") != "ok")' 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    die "Sin respuesta válida en $url. Revisar journalctl -u dogcode -u dogcode-ibmi."
}

[[ ${1:-} != --help ]] || { usage; exit 0; }
[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
domain=$1 email=$2 ibmi=${3:-}
[[ -z $ibmi || $ibmi == --ibmi ]] || die "Opción desconocida: $ibmi"
base=/opt/dogcode state=/var/lib/dogcode conf=/etc/dogcode
repo=https://github.com/mikpidev/dogcode.git
ref=${DOGCODE_REF:-main}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
site=/etc/nginx/sites-available/dogcode

step 1 "Verificar sistema, dominio, parámetros y permisos."
[[ $EUID == 0 ]] || die "Ejecutar con sudo en el servidor destino."
[[ $domain =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "Usa un dominio en minúsculas, sin esquema, ruta ni puerto."
[[ $email =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || die "Email ACME inválido."
[[ $ref =~ ^[[:alnum:]][[:alnum:]_.\/-]*$ ]] || die "Referencia Git inválida."
source /etc/os-release
case "$ID:$VERSION_ID" in ubuntu:24.04|debian:12) ;; *) die "Plataformas previstas: Ubuntu 24.04 o Debian 12.";; esac
[[ -d /run/systemd/system ]] || die "Este deploy requiere systemd como gestor de servicios."
if [[ -f $conf/api.env ]]; then
    grep -Fxq "DOGCODE_DOMAIN=$domain" "$conf/api.env" || die "Este host ya tiene otro dominio configurado para Dogcode."
fi
if [[ -n $ibmi ]]; then
    for f in jt400.jar ibmi.usuario ibmi.password; do
        [[ -s "$conf/$f" ]] || die "Falta $conf/$f (ver README)."
    done
fi

step 2 "Instalar Nginx, Python, venv, Git, certificados y herramientas de despliegue."
export DEBIAN_FRONTEND=noninteractive
apt-get update
pkgs=(nginx python3 python3-venv git ca-certificates curl certbot apache2-utils)
if [[ -n $ibmi ]]; then pkgs+=(openjdk-17-jdk-headless); fi
apt-get install -y --no-install-recommends "${pkgs[@]}"
python3 -c 'import sys; sys.exit(sys.version_info < (3,11))' || die "Se requiere Python 3.11+."

step 3 "Preparar usuario, credenciales web y salidas persistentes sin truncar archivos."
id dogcode >/dev/null 2>&1 || useradd --system --user-group --home-dir "$state" --shell /usr/sbin/nologin dogcode
install -d -m 0755 "$base/releases" "$conf" /var/www/dogcode-acme
install -d -o dogcode -g dogcode -m 0750 "$state" "$state/registros_locales"
if [[ ! -e $state/altas_pendientes.txt ]]; then
    install -o dogcode -g dogcode -m 0640 /dev/null "$state/altas_pendientes.txt"
fi
if [[ ! -s /etc/nginx/dogcode.htpasswd ]]; then
    echo "Crear contraseña web del usuario equipo (distinta de la de IBM i)."
    htpasswd -cB /etc/nginx/dogcode.htpasswd equipo
fi
chown root:www-data /etc/nginx/dogcode.htpasswd
chmod 0640 /etc/nginx/dogcode.htpasswd
printf 'DOGCODE_DOMAIN=%s\n' "$domain" > "$conf/api.env"

step 4 "Descargar Dogcode ($ref), crear venv e instalar requirements.txt en una versión nueva."
release=$(mktemp -d "$base/releases/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
chmod 0755 "$release"
git -C "$release" init --quiet
git -C "$release" fetch --depth=1 "$repo" "$ref"
git -C "$release" checkout --quiet --detach FETCH_HEAD
git -C "$release" rev-parse HEAD > "$release/REVISION"
install -m 0644 "$src/runtime.py" "$release/runtime.py"
install -d -o dogcode -g dogcode "$release/.venv"
runuser -u dogcode -- python3 -m venv "$release/.venv"
py="$release/.venv/bin/python"
runuser -u dogcode -- "$py" -m pip install --disable-pip-version-check -r "$release/requirements.txt"
chown -R root:root "$release/.venv"
install -d "$release/data/registros_locales"
touch "$release/data/altas_pendientes.txt"
if [[ -n $ibmi ]]; then
    chmod 0600 "$conf/ibmi.usuario" "$conf/ibmi.password"
    chmod 0644 "$conf/jt400.jar"
    install -d "$release/jdbc"
    javac -encoding UTF-8 -cp "$conf/jt400.jar" -d "$release/jdbc" "$release/local/ibmi/InsertarSaldo.java"
fi

step 5 "Validar el motor y el adaptador de dominio; activar los servicios locales."
(
    cd "$release"
    runuser -u dogcode -- env PYTHONDONTWRITEBYTECODE=1 "$py" -m app.parser
    runuser -u dogcode -- env PYTHONDONTWRITEBYTECODE=1 DOGCODE_DOMAIN="$domain" "$py" -c \
        'from runtime import api; from app.main import health; assert api() and health()["status"] == "ok"'
)
ln -s "$release" "$base/.current-$$"
mv -Tf "$base/.current-$$" "$base/current"
install -m 0644 "$src/templates/dogcode.service" /etc/systemd/system/dogcode.service
install -m 0644 "$src/templates/dogcode-ibmi.service" /etc/systemd/system/dogcode-ibmi.service
systemctl daemon-reload
if [[ -n $ibmi ]]; then
    systemctl enable dogcode-ibmi
    systemctl restart dogcode-ibmi
    health http://127.0.0.1:8001/health
else
    echo "Modo local: conector IBM i desactivado."
    systemctl disable --now dogcode-ibmi
fi
systemctl enable dogcode
systemctl restart dogcode
health http://127.0.0.1:8000/health

step 6 "Configurar Nginx y emitir o reutilizar el certificado HTTPS de Let's Encrypt."
cert="/etc/letsencrypt/live/$domain/fullchain.pem"
if [[ ! -s $cert ]]; then
    sed "s/@DOMAIN@/$domain/g" "$src/templates/acme.conf" > "$site"
    ln -sfn "$site" /etc/nginx/sites-enabled/dogcode
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    certbot certonly --webroot -w /var/www/dogcode-acme -d "$domain" --cert-name "$domain" \
        --email "$email" --agree-tos --non-interactive
fi
sed "s/@DOMAIN@/$domain/g" "$src/templates/nginx.conf" > "$site"
ln -sfn "$site" /etc/nginx/sites-enabled/dogcode
nginx -t
systemctl enable --now nginx
systemctl reload nginx
install -d /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nset -e\nnginx -t\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/dogcode-nginx
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/dogcode-nginx
systemctl enable --now certbot.timer

step 7 "Comprobar certificado, protección HTTPS y acceso a la API con el Host público."
code=$(curl -sS --max-time 10 --resolve "$domain:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$domain/health")
[[ $code == 401 ]] || die "Nginx debería pedir autenticación (401); devolvió $code."
curl -fsS --max-time 5 -H "Host: $domain" http://127.0.0.1:8000/health
echo
echo "Listo: https://$domain/ | revisión $(cat "$release/REVISION") | usuario web: equipo"
