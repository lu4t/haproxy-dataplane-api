# HAProxy + Data Plane API en Docker (con recargas en caliente)

Este repositorio/documento recoge una configuración *funcionando* de **HAProxy 3.x** en Docker con la **Data Plane API (v3)** incluida en la imagen oficial de HAProxy Technologies. Permite hacer **cambios en caliente** (añadir/quitar *servers* de backends, etc.) mediante la API y recargar de forma segura el proceso maestro de HAProxy desde dentro del contenedor.

---

## 🧩 Arquitectura resumida

- **Imagen**: `haproxytech/haproxy-ubuntu:3.0` (incluye Data Plane API).
- **HAProxy** corre en **master-worker**.
- **Data Plane API** se lanza como `program` dentro de HAProxy.
- **Recarga**: estrategia `custom` + script `reload.sh` (valida y hace *soft reload* `-sf` al PID).  
  > En contenedores **no hay systemd/s6**, por eso `custom` es la opción correcta.
- **Opcional**: página de estadísticas en `:8404` para ver estado de *backends/servers*.

---

## 📁 Estructura de ficheros (en tu directorio de trabajo)

```
.
├─ haproxy.cfg
├─ dataplaneapi.yml
├─ reload.sh
└─ dp-storage/          # estado interno de Data Plane API (nuevo y vacío)
```

> Todo este directorio se montará en `/usr/local/etc/haproxy` dentro del contenedor.

---

## ⚙️ Contenido de los ficheros

### `haproxy.cfg`

```cfg
# _version=2
# Dataplaneapi managed File
# changing file directly can cause a conflict if dataplaneapi is running

global
  master-worker
  pidfile /var/run/haproxy.pid
  stats socket /var/run/haproxy.sock mode 660 level admin

defaults unnamed_defaults_1
  mode http
  timeout connect 5s
  timeout client 30s
  timeout server 30s

userlist dataplaneapi
  user admin insecure-password adminpwd   # ⚠️ cambia credenciales en prod

frontend http from unnamed_defaults_1
  bind *:80
  default_backend app
  http-response add-header X-Served-By haproxy

backend app from unnamed_defaults_1
  # Inicialmente apunta a un backend de prueba llamado 'web' (nginx)
  server s1 web:80 check

# Página de estadísticas (útil para ver UP/DOWN desde el host)
listen stats from unnamed_defaults_1
  bind *:8404
  stats enable
  stats uri /stats
  stats refresh 3s
  stats auth admin:adminpwd  # ⚠️ cambia en prod

program api
  command /usr/local/bin/dataplaneapi -f /usr/local/etc/haproxy/dataplaneapi.yml
  no option start-on-reload
```

---

### `dataplaneapi.yml`

```yaml
config_version: 2

dataplaneapi:
  host: 0.0.0.0
  port: 5555
  user:
    - name: admin
      insecure: true
      password: adminpwd
  resources:
    # Directorio donde Data Plane API guarda su estado interno (nuevo y vacío)
    dataplane_storage_dir: /usr/local/etc/haproxy/dp-storage

haproxy:
  config_file: /usr/local/etc/haproxy/haproxy.cfg
  haproxy_bin: /usr/local/sbin/haproxy
  master_worker_mode: true
  # Recarga via script (custom). En contenedor no hay systemd/s6.
  reload:
    reload_strategy: custom
    validate_cmd: /usr/local/sbin/haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg
    reload_cmd: /usr/local/etc/haproxy/reload.sh
    restart_cmd: /usr/local/etc/haproxy/reload.sh
```

---

### `reload.sh`

```sh
#!/bin/sh
set -eu
CFG="/usr/local/etc/haproxy/haproxy.cfg"

# Validar configuración
/usr/local/sbin/haproxy -c -q -f "$CFG"

# Soft reload si existe PID, si no arranca limpio
if [ -f /var/run/haproxy.pid ]; then
  exec /usr/local/sbin/haproxy -f "$CFG" -sf "$(cat /var/run/haproxy.pid)"
else
  exec /usr/local/sbin/haproxy -f "$CFG"
fi
```

> Recuerda dar permisos de ejecución: `chmod +x reload.sh`

---

## 🚀 Puesta en marcha (paso a paso)

1. **Crear red Docker para balanceo:**
   ```bash
   docker network create lbnet
   ```

2. **Levantar un backend de prueba (nginx) llamado `web`:**
   ```bash
   docker run -d --name web --network lbnet nginx:alpine
   # (Opcional, página para identificar el backend)
   docker exec web sh -c 'printf "web\n" > /usr/share/nginx/html/whoami.html'
   ```

3. **Crear el directorio de estado para Data Plane API:**
   ```bash
   mkdir -p dp-storage
   ```

4. **Arrancar HAProxy con la Data Plane API expuesta en :5555 y stats en :8404:**
   ```bash
   docker run -d --name haproxy --network lbnet \
     -p 80:80 -p 443:443 -p 5555:5555 -p 8404:8404 \
     -v "$PWD":/usr/local/etc/haproxy:rw \
     --restart unless-stopped \
     haproxytech/haproxy-ubuntu:3.0
   ```

   > *Opcional avanzado*: puedes añadir `-S /var/run/haproxy-master.sock` al comando de arranque de HAProxy si deseas exponer el **Master CLI**. No es necesario para esta estrategia `custom`.

5. **Comprobaciones rápidas:**
   ```bash
   # Data Plane API viva
   curl -u admin:adminpwd http://localhost:5555/v3/info

   # HAProxy respondiendo (debería venir de 'web')
   curl -I http://localhost/

   # Stats en HTML (usuario/clave: admin/adminpwd)
   # http://localhost:8404/stats
   ```

---

## 🔄 Cambios en caliente (API v3)

> En API v3, los *servers* cuelgan de la ruta **anidada** por backend:
> `/v3/services/haproxy/configuration/backends/{backend}/servers`

1. **Obtener la versión de configuración actual:**
   ```bash
   CFGVER=$(curl -s -u admin:adminpwd \
     http://localhost:5555/v3/services/haproxy/configuration/version | tr -dc '0-9')
   echo "$CFGVER"
   ```

2. **Añadir un nuevo backend de prueba `lala`:**
   ```bash
   docker run -d --name lala --network lbnet nginx:alpine
   docker exec lala sh -c 'printf "lala\n" > /usr/share/nginx/html/whoami.html'
   ```

3. **Añadir el *server* `lala` al backend `app` y recargar:**
   ```bash
   curl -u admin:adminpwd -X POST \
     "http://localhost:5555/v3/services/haproxy/configuration/backends/app/servers?version=$CFGVER&force_reload=true" \
     -H "Content-Type: application/json" \
     -d '{"name":"lala","address":"lala","port":80,"check":"enabled"}'
   ```

4. **(Opcional) Drenar y eliminar el *server* antiguo `s1` (apunta a `web`):**
   ```bash
   # Marcar s1 en mantenimiento (no entran nuevas conexiones)
   CFGVER=$(curl -s -u admin:adminpwd http://localhost:5555/v3/services/haproxy/configuration/version)
   curl -u admin:adminpwd -X PUT \
     "http://localhost:5555/v3/services/haproxy/configuration/backends/app/servers/s1?version=$CFGVER&force_reload=true" \
     -H "Content-Type: application/json" \
     -d '{"name":"s1","address":"web","port":80,"maintenance":"enabled"}'

   # Borrar s1 cuando esté drenado
   CFGVER=$(curl -s -u admin:adminpwd http://localhost:5555/v3/services/haproxy/configuration/version)
   curl -u admin:adminpwd -X DELETE \
     "http://localhost:5555/v3/services/haproxy/configuration/backends/app/servers/s1?version=$CFGVER&force_reload=true"
   ```

5. **Verificar configuración y estado en runtime:**
   ```bash
   # Listar servers del backend app (config actual)
   curl -u admin:adminpwd \
     "http://localhost:5555/v3/services/haproxy/configuration/backends/app/servers"

   # Ver estado via stats (CSV) y filtrar líneas de 'app'
   curl -u admin:adminpwd "http://localhost:8404/stats;csv" | grep ",app,"

   # Probar qué backend responde
   for i in $(seq 1 5); do curl -s http://localhost/whoami.html; done
   ```

---

## 🛡️ Seguridad y buenas prácticas

- **Cambia** todas las credenciales por defecto (`userlist`, `stats auth`, usuarios de la API).
- **Restringe** el acceso a la API (`:5555`) con firewall, redes privadas o *reverse proxy* con auth.
- Monta los ficheros como **solo lectura** en producción (`:ro`) y gestiona cambios via API.
- Versiona estos tres ficheros (`haproxy.cfg`, `dataplaneapi.yml`, `reload.sh`).

---

## 🧱 Problemas comunes (FAQ rápido)

- **“custom reload strategy requires ReloadCmd/RestartCmd”**  
  → Asegúrate de tener el bloque `haproxy.reload` con `reload_strategy: custom` y `reload_cmd`/`restart_cmd`/`validate_cmd`. Evita restos de configuraciones previas en el *storage*; usa un `dp-storage` limpio.

- **“invalid reload strategy: 'native'”**  
  → La CLI solo admite `systemd | s6 | custom`. En Docker, usa **`custom`** + script.

- **No se crea el master socket**  
  → Si usas `-S /var/run/haproxy/master.sock`, crea antes la carpeta o usa un path plano como `/var/run/haproxy-master.sock`. (Para este setup **no es necesario** usar `-S`.)

- **404 al hacer PUT/POST de servers**  
  → En v3, la ruta correcta es `/v3/services/haproxy/configuration/backends/<backend>/servers` (no `/configuration/servers/...`).

- **Backend DOWN / connection refused**  
  → Asegúrate de que tu destino existe en la **misma red** Docker y usa **nombre de contenedor** (`web:80`, `lala:80`).

---

## 🧪 Comandos útiles de verificación

```bash
# Info de API
curl -u admin:adminpwd http://localhost:5555/v3/info

# Versión de configuración
curl -u admin:adminpwd http://localhost:5555/v3/services/haproxy/configuration/version

# Backends
curl -u admin:adminpwd http://localhost:5555/v3/services/haproxy/configuration/backends

# Servers de un backend
curl -u admin:adminpwd \
  "http://localhost:5555/v3/services/haproxy/configuration/backends/app/servers"
```

---

## 📝 Licencia / Créditos

- Imagen: © HAProxy Technologies.  
- Este README se ofrece tal cual, para propósitos de demostración/operación.

---

## 📦 TL;DR

1. Crea `haproxy.cfg`, `dataplaneapi.yml`, `reload.sh` y `dp-storage/` según arriba.  
2. `docker network create lbnet`  
3. `docker run -d --name web --network lbnet nginx:alpine`  
4. `docker run -d --name haproxy --network lbnet -p 80:80 -p 443:443 -p 5555:5555 -p 8404:8404 -v "$PWD":/usr/local/etc/haproxy:rw --restart unless-stopped haproxytech/haproxy-ubuntu:3.0`  
5. `curl -u admin:adminpwd http://localhost:5555/v3/info`  
6. Cambios en caliente: usa los endpoints v3 (añadir `lala`, drenar y borrar `s1`).

¡Listo! Con esto puedes copiar/pegar en tu repo y subir a GitHub del tirón.
