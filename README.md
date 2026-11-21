# Desplegar Dogcode en un solo servidor

Instala la web y API de [mikpidev/dogcode](https://github.com/mikpidev/dogcode) detrás de Nginx con HTTPS y autenticación para el equipo. La web estática se sirve desde FastAPI. No requiere Node, Docker ni una base de datos local.

```text
Navegador → Nginx :443 → Uvicorn 127.0.0.1:8000 → TXT/DAT
                                      └─ opcional → 127.0.0.1:8001 → JDBC/TLS → PUB400
```

## Antes de empezar

- Servidor dedicado o VPS con **Ubuntu 24.04 LTS o Debian 12**, `systemd`, acceso `sudo`, Git para clonar este repo y salida a los repositorios del SO, GitHub, PyPI y Let's Encrypt.
- Dominio o subdominio con su registro **A** apuntando al servidor. Si publicas un **AAAA**, también debe llegar al servidor por IPv6. Permite entrada TCP **80 y 443** en el firewall de la máquina y del proveedor. No abras 8000 ni 8001.
- Nginx debe poder usar 80/443. Se crea el vhost `sites-available/dogcode`; no dupliques el mismo `server_name` en otro sitio. No se modifica el firewall, DNS ni el sitio por defecto.
- Si tienes datos locales que quieras trasladar, respáldalos. El deploy parte del código de GitHub y de los datos persistentes que existan **en el servidor**: no copia archivos desde tu laptop.

## Ejecutar

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/mikpidev/hackatonDeploy.git
cd hackatonDeploy
sudo bash deploy.sh motor.ejemplo.com admin@ejemplo.com
```

Reemplaza el dominio y correo. En el primer despliegue `htpasswd` te pedirá la contraseña web para **equipo**; en los siguientes se conserva. Para ejecución sin terminal, prepara antes `/etc/nginx/dogcode.htpasswd` con un usuario y hash válidos. No pases contraseñas en la línea de comandos.

Por defecto despliega `main` del motor. Para fijar una versión reproducible:

```bash
sudo env DOGCODE_REF=c809507e6eb5f158f482e48434696257b3a437ee \
  bash deploy.sh motor.ejemplo.com admin@ejemplo.com
```

### Qué hace cada stage

| Stage | Acción | Qué verificar si falla |
|---|---|---|
| 1. Preflight | Valida dominio, email, SO, `systemd`, permisos y archivos opcionales de IBM i. | Comando, distro y rutas. |
| 2. Paquetes | Instala Nginx, Python 3.11+, `venv`, Git, curl, CA, Certbot y `apache2-utils`. Añade JDK 17 solo con `--ibmi`. | Acceso a APT. |
| 3. Estado | Crea usuario de servicio sin login, directorios persistentes y autenticación web. No trunca altas existentes. | Permisos y contraseña web inicial. |
| 4. Release | Descarga la referencia Git a una carpeta nueva, crea su entorno Python e instala las versiones de `requirements.txt`. Con IBM i compila el puente JDBC. | Acceso a GitHub/PyPI y, si aplica, `jt400.jar`. |
| 5. API | Prueba el parser, la configuración del dominio y la lectura del archivo. Cambia el enlace `current`, configura `systemd` y espera `/health`. Usa un worker para las escrituras locales. | `journalctl -u dogcode` y puertos locales libres. |
| 6. HTTPS | Si falta el certificado, abre solo el reto HTTP ACME. Después instala el vhost TLS, prueba `nginx -t`, activa redirección a HTTPS y renovación automática. | DNS, firewall y disponibilidad de 80/443. |
| 7. Verificación | Comprueba que HTTPS presenta un certificado válido y pide autenticación (401); verifica el backend con el hostname público. | Nginx, credenciales y encabezados del proxy. |

Cada stage imprime su acción con `echo`. El script usa `set -Eeuo pipefail`: se detiene ante errores e indica el stage. **No hay rollback automático**: si falla después de activar el servicio, puede estar corriendo la nueva versión aunque HTTPS aún no esté listo. Corrige la causa y repite el comando.

## Conector IBM i opcional

El modo por defecto trabaja con archivos. Para habilitar la inserción en el PF de pruebas `MIKEPIDEV1/SALDOSTST`, se necesita un perfil autorizado, salida desde el servidor al servicio JDBC/TLS de PUB400 (puerto configurado **9471** y servicios de sign-on que requiera IBM i) y el JAR de IBM Toolbox/JTOpen usado por el motor. No se instala el emulador 5250.

Prepara los archivos en el servidor, sin guardarlos en Git:

```bash
sudo install -d -m 0755 /etc/dogcode
sudo install -m 0644 /ruta/a/jt400.jar /etc/dogcode/jt400.jar
sudo install -m 0600 /dev/null /etc/dogcode/ibmi.usuario
sudo install -m 0600 /dev/null /etc/dogcode/ibmi.password
sudoedit /etc/dogcode/ibmi.usuario    # una línea: usuario
sudoedit /etc/dogcode/ibmi.password   # una línea: contraseña
sudo bash deploy.sh motor.ejemplo.com admin@ejemplo.com --ibmi
```

El servicio usa `LoadCredential` de systemd. La contraseña de IBM i y la de la web son **distintas**. Al actualizar, vuelve a pasar `--ibmi` si quieres mantener el conector encendido. Sin ese flag se desactiva. El chequeo de salud confirma el arranque, **no inserta filas ni certifica acceso a Db2**. Los GET del motor actual siguen leyendo archivos: este despliegue no crea sincronización ni lectura en vivo desde IBM i.

## Datos, servicios y operación

- Código: `/opt/dogcode/releases/`; `/opt/dogcode/current` señala la versión activa. `REVISION` contiene el commit. El adaptador de arranque autoriza el dominio configurado, sin permitir hosts ni orígenes comodín.
- Escrituras: `/var/lib/dogcode/altas_pendientes.txt` y `/var/lib/dogcode/registros_locales/`. systemd los monta en la ruta que espera el motor. Respáldalos antes de actualizar. Los originales y perfiles incluidos con la release son de solo lectura para el servicio; los cambios manuales dentro de `current` no se trasladan a otra versión.
- Verificar la web y la API (curl solicita la contraseña): `curl -u equipo https://motor.ejemplo.com/health`. Probar con `GET /clientes/C000002/saldo`. No se necesitan escrituras para validar el despliegue.
- Estado/logs: `systemctl status dogcode nginx` y `journalctl -u dogcode -n 80 --no-pager`. Con JDBC: `journalctl -u dogcode-ibmi -n 80 --no-pager`.
- Actualizar: `git pull --ff-only` en **este repo** y volver a ejecutar el deploy. Si hay una automatización activa, no ejecutar dos despliegues simultáneos. Rotar el acceso web con `sudo htpasswd -B /etc/nginx/dogcode.htpasswd equipo`.
- Certificados: `sudo certbot renew --dry-run`. No desactivar el acceso HTTP al reto ACME tras la primera emisión.
