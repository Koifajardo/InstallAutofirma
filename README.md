# Instalación de AutoFirma + Zen Browser (Flatpak)

Configuración probada y funcional para **AutoFirma 1.9** + **Zen Browser** (ambos como Flatpak) que permite **firmar electrónicamente** en webs de la Administración Pública (VEA, Cl@ve, Sede Electrónica, etc.).

## Contexto / Problema

AutoFirma (cuando se instala por Flatpak) abre el protocolo `afirma://` y arranca un servidor **WebSocket seguro (wss://)** en `127.0.0.1:PUERTO` para que la web desde la que firmas pueda comunicarse con él.

Sin embargo, por defecto:

1. El navegador **no confía en el certificado SSL** auto-firmado de AutoFirma → la conexión WebSocket falla (`Firefox can't establish a connection…`).
2. Zen Browser en Flatpak **no ve el trust store del sistema** (`/etc/ssl/certs/`).
3. El `/tmp` dentro del sandbox del Flatpak de AutoFirma **es privado**, por lo que `certutil -d sql:/tmp/...` no escribe en el `/tmp` real del host (esto nos costó varias iteraciones).
4. El protocolo `afirma://` no está asociado por defecto en Zen (aparece `action: 4` en `handlers.json`).

Esta guía/script soluciona todo esto.

## Requisitos

- Linux (probado en Ubuntu 24.04.4 LTS; debería funcionar en cualquier distro basada en Debian/Ubuntu)
- `flatpak` instalado y con el remoto `flathub` activo
- `openssl`, `python3`
- Acceso `sudo` para añadir el CA al trust store del sistema
- Un entorno gráfico (X11 o Wayland)

## Archivos de este repositorio

| Archivo                          | Descripción                                                            |
|----------------------------------|------------------------------------------------------------------------|
| `README.md`                      | Este documento                                                         |
| `install.sh`                     | Script principal. Hace toda la instalación/configuración.              |
| `prefs.js`                       | Preferencias de Zen que se copian al perfil como `user.js`.            |
| `handlers.json.patch.py`         | Parche Python que cambia `afirma` a `action: 3` en el perfil de Zen.   |
| `policies.json.tmpl`             | Plantilla de políticas de Firefox (con `@HOME@` como placeholder).    |

> AutoFirma generará automáticamente `~/.afirma/Autofirma/Autofirma_ROOT.cer` la primera vez que se arranque; ese fichero **no** se distribuye en este repositorio (es específico de cada máquina/usuario).

## Instalación

### Opción rápida (script)

```bash
./install.sh
```

El script es **idempotente**: se puede reejecutar sin problema. Pedirá `sudo` para copiar el CA a `/usr/local/share/ca-certificates/` y regenerar el trust store.

> ⚠️ Antes de ejecutarlo, **abre Zen Browser al menos una vez** y ciérralo. Esto crea el perfil de usuario donde se inyectan las configuraciones. El script fallará si no encuentra ningún perfil con `cert9.db`.

### Opción manual (paso a paso)

Ver abajo, sección [Proceso manual](#proceso-manual).

## Qué hace el script

### 1. Instala Flatpaks

```bash
flatpak install -y flathub app.zen_browser.zen
flatpak install -y flathub es.gob.afirma
```

Si ya están instalados, los omite.

### 2. Inicia AutoFirma una vez

Esto genera automáticamente en `~/.afirma/Autofirma/`:

```
autofirma.pfx            # Keystore SSL de AutoFirma (servidor WSS)
Autofirma_ROOT.cer       # CA raíz auto-firmada
script.sh / uninstall.sh # Instalan/desinstalan el CA en navegadores
```

Si no se ha generado todavía, el script ejecuta AutoFirma y lo cierra con un `SIGTERM`:

```bash
flatpak run es.gob.afirma &
sleep 10
pkill -f "autofirma.jar"
```

### 3. Copia el CA al trust store del sistema

```bash
sudo cp ~/.afirma/Autofirma/Autofirma_ROOT.cer \
        /usr/local/share/ca-certificates/autofirma-root.crt
sudo update-ca-certificates
```

**IMPORTANTE**: El `.cer` debe estar en formato PEM (no DER). El script lo convierte automáticamente si hace falta:

```bash
openssl x509 -in ~/.afirma/Autofirma/Autofirma_ROOT.cer \
             -out /tmp/autofirma-root.pem
mv /tmp/autofirma-root.pem ~/.afirma/Autofirma/Autofirma_ROOT.cer
```

### 4. Regenera el bundle `ca-certificates.crt`

En algunas versiones de Ubuntu/Debian, `update-ca-certificates` crea el symlink `<hash>.0` correctamente pero no inserta el certificado en el bundle agregado `/etc/ssl/certs/ca-certificates.crt` (que es el que realmente leen algunas aplicaciones). El script verifica esto y añade manualmente el certificado si hace falta:

```bash
if ! grep -q "Autofirma" /etc/ssl/certs/ca-certificates.crt; then
    sudo sh -c 'cat /usr/local/share/ca-certificates/autofirma-root.crt \
                >> /etc/ssl/certs/ca-certificates.crt'
fi
```

### 5. Da permisos a Zen Browser para ver el trust store del host

Por defecto, el sandbox de Zen no puede leer `/etc/ssl/certs/`. Le damos acceso con:

```bash
flatpak override --user --filesystem=host-etc app.zen_browser.zen
```

`host-etc` mapea el `/etc` del host como `/run/host/etc` dentro del sandbox de Zen.

### 6. Habilita `enterprise_roots` en Zen

Se copia `prefs.js` al perfil como `user.js`:

```bash
cp prefs.js "$PROFILE_DIR/user.js"
```

`prefs.js` contiene:

```js
user_pref("network.protocol-handler.external.afirma", true);   // Permitir handler externo
user_pref("network.protocol-handler.warn-external.afirma", false); // No preguntar
user_pref("network.protocol-handler.expose.afirma", false);    // Delegar al SO
user_pref("security.enterprise_roots.enabled", true);          // Importar CAs del sistema
```

Con `enterprise_roots = true`, Zen leerá los CAs del sistema (que ahora incluye Autofirma ROOT).

### 7. Genera el policies.json (con tu ruta real de $HOME)

El script genera `policies.json` dentro del perfil dinámicamente, sustituyendo `@HOME@` por el valor real de `$HOME`:

```json
{
  "policies": {
    "Certificates": {
      "Install": ["$HOME/.afirma/Autofirma/Autofirma_ROOT.cer"]
    }
  }
}
```

Esto fuerza a Zen a instalar el CA en su cert9.db al arrancar.

### 8. Configura el protocolo `afirma://` en Zen

Modifica `<profile>/handlers.json` cambiando:

```json
"afirma": {"action": 4}
```

por:

```json
"afirma": {"action": 3}
```

`action: 3` significa "usar el handler por defecto del sistema" (que ya está registrado como `es.gob.afirma.desktop`).

### 9. Instala el CA en el cert9.db del perfil de Zen

Esta es la parte más delicada. Hay dos reglas críticas:

- **Regla 1**: El `/tmp` dentro del sandbox del Flatpak de AutoFirma **es privado**. No esperes que un fichero en `/tmp` escrito por el Flatpak esté en el `/tmp` del host (y viceversa).
- **Regla 2**: Hay que operar sobre un directorio **común** visible desde ambos sandboxes. El script usa `~/.cache/afirma-install-work/` (no `/tmp`).

```bash
PROFILE="$(find ~/.var/app/app.zen_browser.zen/.zen -maxdepth 1 \
            -type d -name '*Default*release*' | head -1)"
WORK=~/.cache/afirma-install-work
mkdir -p "$WORK"
cp "$PROFILE/cert9.db"    "$WORK/cert9.db"
cp "$PROFILE/key4.db"     "$WORK/key4.db"
cp "$PROFILE/pkcs11.txt"  "$WORK/pkcs11.txt"

flatpak run --command=sh es.gob.afirma -c "
    certutil -d sql:$WORK -A -n SocketAutoFirma \
             -i $HOME/.afirma/Autofirma/Autofirma_ROOT.cer \
             -t CT,C,C
"

cp "$WORK/cert9.db"   "$PROFILE/cert9.db"
cp "$WORK/key4.db"    "$PROFILE/key4.db"
rm -rf "$WORK"
```

Trust flags usados: **`CT,C,C`**

- `CT` = trusted as CA for SSL/TLS server auth (C = CA, T = trusted for issuing SSL certs).
- `C`  = trusted for S/MIME email protection.
- `C`  = trusted for code signing (JAR/XPI).

### 10. Mata procesos antiguos de AutoFirma

Por si quedan procesos colgados con puertos WebSocket antiguos que ya no coinciden con la sesión actual:

```bash
pkill -f "autofirma.jar" || true
```

### 11. Instala el CA en NSS DB de Chrome (~/.pki/nssdb)

Opcional pero recomendable para que Chrome/Chromium también puedan conectarse a AutoFirma:

```bash
mkdir -p ~/.pki/nssdb
flatpak run --command=sh es.gob.afirma -c '
    certutil -d sql:$HOME/.pki/nssdb \
             -A -n "SocketAutoFirma" \
             -i $HOME/.afirma/Autofirma/Autofirma_ROOT.cer \
             -t "CT,C,C"
'
```

## Proceso manual

Si prefieres no usar el script y hacerlo a mano:

1. Instala los flatpaks:
   ```bash
   flatpak install -y flathub app.zen_browser.zen
   flatpak install -y flathub es.gob.afirma
   ```

2. Abre AutoFirma por primera vez:
   ```bash
   flatpak run es.gob.afirma &
   sleep 10
   pkill -f "autofirma.jar"
   ```

3. Abre Zen Browser una vez y ciérralo. Necesitas haber creado el perfil (Zen genera el directorio al primer arranque).

4. Detecta tu perfil de Zen:
   ```bash
   ls -d ~/.var/app/app.zen_browser.zen/.zen/* | grep -i "release"
   # El nombre del directorio será algo así:
   #   ~/.var/app/app.zen_browser.zen/.zen/XXXXXXXX.Default Profile/
   #   ~/.var/app/app.zen_browser.zen/.zen/XXXXXXXX.Default (release)/
   ```

5. Convierte el CA a PEM si hace falta:
   ```bash
   if ! head -1 ~/.afirma/Autofirma/Autofirma_ROOT.cer | grep -q "BEGIN CERT"; then
       openssl x509 -in ~/.afirma/Autofirma/Autofirma_ROOT.cer \
                    -out /tmp/autofirma-root.pem
       cp /tmp/autofirma-root.pem ~/.afirma/Autofirma/Autofirma_ROOT.cer
   fi
   ```

6. Instala el CA en el trust store del sistema:
   ```bash
   sudo cp ~/.afirma/Autofirma/Autofirma_ROOT.cer \
           /usr/local/share/ca-certificates/autofirma-root.crt
   sudo update-ca-certificates
   # Por si el bundle no se completa:
   if ! grep -q "Autofirma" /etc/ssl/certs/ca-certificates.crt; then
       sudo sh -c 'cat /usr/local/share/ca-certificates/autofirma-root.crt \
                    >> /etc/ssl/certs/ca-certificates.crt'
   fi
   ```

7. Da permiso a Zen de leer `/etc` del host:
   ```bash
   flatpak override --user --filesystem=host-etc app.zen_browser.zen
   ```

8. Configura el perfil de Zen (sustituye `XXX.Default (release)` por el nombre de tu perfil):
   ```bash
   PROFILE="$HOME/.var/app/app.zen_browser.zen/.zen/XXX.Default (release)"
   mkdir -p "$PROFILE/distribution"
   cp prefs.js        "$PROFILE/user.js"
   cp policies.json.tmpl "$PROFILE/distribution/policies.json"
   # Sustituye @HOME@ por $HOME en policies.json
   sed -i "s|@HOME@|$HOME|g" "$PROFILE/distribution/policies.json"
   ```

9. Aplica el parche `afirma:// action:3` en `handlers.json`:
   ```bash
   python3 handlers.json.patch.py "$PROFILE/handlers.json"
   ```

10. Instala el CA en el `cert9.db` del perfil de Zen (usando workspace compartido, **no** /tmp):
    ```bash
    WORK=$HOME/.cache/afirma-install-work
    mkdir -p "$WORK"
    cp "$PROFILE/cert9.db"    "$WORK/cert9.db"
    cp "$PROFILE/key4.db"     "$WORK/key4.db"
    cp "$PROFILE/pkcs11.txt"  "$WORK/pkcs11.txt"
    flatpak run --command=sh es.gob.afirma -c "
        certutil -d sql:$WORK \
                 -A -n SocketAutoFirma \
                 -i $HOME/.afirma/Autofirma/Autofirma_ROOT.cer \
                 -t CT,C,C
    "
    cp "$WORK/cert9.db"   "$PROFILE/cert9.db"
    cp "$WORK/key4.db"    "$PROFILE/key4.db"
    rm -rf "$WORK"
    ```

11. Mata procesos antiguos de AutoFirma y cierra Zen:
    ```bash
    pkill -f "autofirma.jar" || true
    pkill -f "app.zen_browser.zen" || true
    rm -f "$PROFILE/lock"
    ```

12. Abre Zen e intenta firmar en VEA. Debería lanzar AutoFirma y mostrar el selector de certificados.

## Diagnóstico / Comprobaciones rápidas

### ¿AutoFirma se arranca bien?

```bash
flatpak run es.gob.afirma
```

Debería abrir el GUI sin errores de configuración.

### ¿Hay puertos WebSocket a la escucha?

```bash
ss -tlnp | grep java
```

### ¿El cert del servidor WSS es válido?

```bash
PORT=$(ss -tlnp 2>/dev/null | grep -m1 java | awk '{print $4}' | awk -F: '{print $NF}')
echo | openssl s_client -connect 127.0.0.1:$PORT -showcerts 2>/dev/null | \
    openssl x509 -text -noout | head -20
```

Debería verse:
```
Subject: CN=127.0.0.1
Issuer:  CN=Autofirma ROOT
Subject Alternative Name:
    IP: 127.0.0.1, DNS: localhost
```

### ¿El CA está en el trust store del sistema?

```bash
CA_HASH=$(openssl x509 -hash -noout \
          -in /usr/local/share/ca-certificates/autofirma-root.crt)
echo "Hash: $CA_HASH"
ls /etc/ssl/certs/ | grep "$CA_HASH"
grep -c "Autofirma" /etc/ssl/certs/ca-certificates.crt
```

Los dos comandos deben producir salida (el `grep` debe dar `1` o más).

### ¿Zen puede ver el trust store?

```bash
CA_HASH=$(openssl x509 -hash -noout \
          -in /usr/local/share/ca-certificates/autofirma-root.crt)
flatpak run --command=sh app.zen_browser.zen -c \
    "ls /run/host/etc/ssl/certs/$CA_HASH.0"
```

### ¿El CA está en el cert9.db de Zen?

```bash
PROFILE="$(find ~/.var/app/app.zen_browser.zen/.zen -maxdepth 1 \
           -type d -name '*Default*release*' | head -1)"
WORK=$HOME/.cache/afirma-install-work
mkdir -p "$WORK"
cp "$PROFILE/cert9.db"   "$WORK/cert9.db"
cp "$PROFILE/key4.db"    "$WORK/key4.db"
cp "$PROFILE/pkcs11.txt" "$WORK/pkcs11.txt"
flatpak run --command=sh es.gob.afirma -c \
    'certutil -L -d sql:'"$WORK"' | grep -i afirma'
rm -rf "$WORK"
```

Debe listar `SocketAutoFirma  CT,C,C`.

### ¿Está bien el `handlers.json`?

```bash
PROFILE="$(find ~/.var/app/app.zen_browser.zen/.zen -maxdepth 1 \
           -type d -name '*Default*release*' | head -1)"
python3 -c "import json;d=json.load(open('$PROFILE/handlers.json'));print(d['schemes']['afirma'])"
```

Debe salir `{'action': 3}`.

## Notas / Advertencias

- **No uses `/tmp`** como directorio intermedio entre el Flatpak de AutoFirma y el host. El `/tmp` dentro del sandbox de un Flatpak es **privado y efímero**. Usa siempre un subdirectorio dentro de `$HOME` (por ejemplo `~/.cache/afirma-install-work/`).
- **Cada vez que regeneres la configuración de AutoFirma** (por ejemplo al reinstalar el Flatpak o borrar `~/.afirma/`), el `autofirma.pfx` y `Autofirma_ROOT.cer` se regeneran con nuevos hashes. Repite el script para reinstalar el CA en el trust store y en el perfil de Zen.
- **El hash `<xxxxxxx>.0`** es específico de cada CA (depende del contenido del certificado). Ejecuta este comando para ver tu hash:
  ```bash
  openssl x509 -hash -noout -in ~/.afirma/Autofirma/Autofirma_ROOT.cer
  ```
- **Puedes ejecutar varias veces el script**: es seguro y no sobreescribe nada importante.
- Si cambia el perfil de Zen (por ejemplo creas un perfil nuevo), vuelve a aplicar los pasos 5–8 a ese perfil.
- **El perfil de Zen tiene un nombre con un prefijo aleatorio de 8 caracteres** (por ejemplo `50i3pjml.Default (release)`). El script lo detecta automáticamente, pero si lo haces a mano tendrás que sustituirlo por tu propio nombre de perfil.

## Estado / Resultado

Tras ejecutar `install.sh` y reiniciar Zen Browser, el flujo para firmar en VEA es:

1. Vas a `https://veaja.cloud.juntadeandalucia.es/inicio/procedimiento-detalle/PEG_VEA/borrador/…`
2. Haces clic en **Firmar**.
3. La web lanza `afirma://websocket?ports=…&idsession=…`.
4. Zen abre AutoFirma vía `xdg-open` (handler `es.gob.afirma.desktop`).
5. AutoFirma arranca un servidor WSS en `127.0.0.1:PUERTO`.
6. Zen confía en el cert SSL porque Autofirma ROOT está en el trust store del sistema + en el cert9.db del perfil.
7. AutoFirma se conecta y muestra el selector de certificados.
8. Seleccionas el certificado (en este caso, el certificado personal de la FNMT) y firmas.
9. El documento firmado se envía a través del WebSocket y VEA lo registra.

Todo el proceso es transparente una vez configurado.

## Licencia

Código de este repositorio: libre uso, modificación y redistribución (MIT).

AutoFirma y Zen Browser son software libre con sus respectivas licencias:
- AutoFirma: GPLv2 (https://github.com/ctt-gob-es/clienteafirma)
- Zen Browser: MPL 2.0 (https://github.com/zen-browser)