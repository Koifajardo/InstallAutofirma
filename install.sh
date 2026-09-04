#!/usr/bin/env bash
# Instalación y configuración completas de AutoFirma + Zen Browser (ambos Flatpak).
# Probado en Ubuntu 24.04.4 LTS con Zen 1.21.8b y AutoFirma 1.9.
# Idempotente: se puede ejecutar varias veces sin romper nada.

set -e

# ── CONSTANTES (todas derivadas de $HOME, sin rutas hardcoded) ───
ZEN_APP="app.zen_browser.zen"
AFIRMA_APP="es.gob.afirma"
HOST_HOME="${HOME}"
AFIRMA_DIR="$HOST_HOME/.afirma/Autofirma"
CA_CER="$AFIRMA_DIR/Autofirma_ROOT.cer"
ZEN_PROFILE_PARENT="$HOST_HOME/.var/app/$ZEN_APP/.zen"
NSS_DB="$HOST_HOME/.pki/nssdb"
CERT_DIR_HOST="/usr/local/share/ca-certificates"
WORK_DIR="$HOST_HOME/.cache/afirma-install-work"

# (el /tmp del sandbox del Flatpak es PRIVADO: NUNCA uses /tmp como puente)

# ── HELPERS ──────────────────────────────────────────────────────
log()   { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[FAIL]\033[0m  $*"; }

sudo_cmd() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ── PRE-REQUISITOS ──────────────────────────────────────────────
log "Comprobando pre-requisitos…"
command -v flatpak >/dev/null 2>&1 || { err "flatpak no está instalado"; exit 1; }
command -v openssl  >/dev/null 2>&1 || { err "openssl no está instalado"; exit 1; }
command -v python3  >/dev/null 2>&1 || { err "python3 no está instalado"; exit 1; }
command -v jq       >/dev/null 2>&1 || warn "jq no está instalado (algunas comprobaciones del README fallarán)"
ok "Pre-requisitos OK"

# Zen NO debe estar corriendo: mantiene cert9.db en memoria y lo sobreescribe
# al cerrarse, borrando el CA que instale este script (Paso 9).
if pgrep -x zen >/dev/null 2>&1; then
    err "Zen Browser está corriendo. Ciérralo antes de ejecutar este script,"
    err "si no el CA instalado en cert9.db se perderá al cerrarse Zen."
    err "   Ciérralo con:  flatpak kill app.zen_browser.zen  (o pkill -x zen)"
    exit 1
fi

# ── PASO 1: Instalar Flatpaks ────────────────────────────────────
log "Paso 1: Instalación de Flatpaks (AutoFirma y Zen Browser)"
if ! flatpak list 2>/dev/null | grep -qi "$AFIRMA_APP"; then
    flatpak install -y flathub "$AFIRMA_APP"
else
    ok "AutoFirma ya instalado"
fi
if ! flatpak list 2>/dev/null | grep -qi "$ZEN_APP"; then
    flatpak install -y flathub "$ZEN_APP"
else
    ok "Zen Browser ya instalado"
fi
ok "Flatpaks listos"

# ── PASO 2: Generar el CA de AutoFirma (si no existe) ────────────
log "Paso 2: Inicializar AutoFirma (genera Autofirma_ROOT.cer)"
if [ ! -f "$CA_CER" ]; then
    warn "AutoFirma no había generado certificados. Lanzándolo para generarlos…"
    flatpak run "$AFIRMA_APP" >/dev/null 2>&1 &
    AF_PID=$!
    sleep 10
    kill "$AF_PID" 2>/dev/null || true
    for _ in $(seq 1 6); do
        [ -f "$CA_CER" ] && break
        sleep 1
    done
fi
[ -f "$CA_CER" ] || {
    err "No se pudo inicializar AutoFirma. Lanzar manual: flatpak run $AFIRMA_APP"
    exit 1
}
ok "Certificado CA disponible: $CA_CER"

# Convertir a PEM si está en DER
if ! head -1 "$CA_CER" 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
    log "Convirtiendo CA de DER a PEM…"
    openssl x509 -in "$CA_CER" -out "$CA_CER.pem" && mv "$CA_CER.pem" "$CA_CER"
fi

# ── PASO 3: Instalar el CA en el trust store del sistema ────────
log "Paso 3: Instalar CA en $CERT_DIR_HOST/ (requiere sudo)"
sudo_cmd cp "$CA_CER" "$CERT_DIR_HOST/autofirma-root.crt"
sudo_cmd update-ca-certificates
# Verificar el bundle (a veces no se actualiza)
if ! sudo_cmd sh -c 'grep -q "Autofirma" /etc/ssl/certs/ca-certificates.crt'; then
    warn "El bundle ca-certificates.crt no incluye Autofirma. Añadiéndolo manualmente…"
    sudo_cmd sh -c "cat $CERT_DIR_HOST/autofirma-root.crt >> /etc/ssl/certs/ca-certificates.crt"
fi
ok "Trust store del sistema actualizado"

# ── PASO 4: Permitir que Zen vea /etc del host ──────────────────
log "Paso 4: Override de filesystem para que Zen acceda a /etc/ssl/certs del host"
flatpak override --user --filesystem=host-etc "$ZEN_APP"
ok "Override aplicado"

# ── PASO 5: Detectar perfil de Zen ──────────────────────────────
log "Paso 5: Localizar perfil de Zen"
ZEN_PROFILE=""
if [ -d "$ZEN_PROFILE_PARENT" ]; then
    # Preferimos el perfil "Default (release)"
    for dir in "$ZEN_PROFILE_PARENT"/*; do
        if [ -f "$dir/cert9.db" ]; then
            if basename "$dir" | grep -q "Default (release)"; then
                ZEN_PROFILE="$dir"
                break
            elif [ -z "$ZEN_PROFILE" ]; then
                ZEN_PROFILE="$dir"
            fi
        fi
    done
fi
[ -z "$ZEN_PROFILE" ] && {
    err "No se encontró perfil de Zen. Lánzalo una vez primero y vuelve a correr este script."
    exit 1
}
ok "Perfil: $ZEN_PROFILE"

# ── PASO 6: Configurar prefs.js / user.js ──────────────────────
log "Paso 6: Configurar prefs de Zen (handlers afirma:// + enterprise_roots)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/prefs.js" ] && cp "$SCRIPT_DIR/prefs.js" "$ZEN_PROFILE/user.js"
ok "user.js copiado al perfil"

# ── PASO 7: Generar policies.json con ruta absoluta del usuario ──
log "Paso 7: Generar policies.json (con la ruta del usuario actual)"
mkdir -p "$ZEN_PROFILE/distribution"
cat > "$ZEN_PROFILE/distribution/policies.json" << EOF
{
  "policies": {
    "Certificates": {
      "Install": [
        "$CA_CER"
      ]
    }
  }
}
EOF
ok "policies.json generado en el perfil"

# ── PASO 8: Parchear handlers.json (afirma:// → stubEntry) ─────
log "Paso 8: Parchear handlers.json"
if [ -f "$ZEN_PROFILE/handlers.json" ]; then
    python3 "$SCRIPT_DIR/handlers.json.patch.py" "$ZEN_PROFILE/handlers.json"
else
    # Crear handlers.json mínimo si no existe (formato stubEntry, NO action)
    python3 -c "
import json, os
d = {'defaultHandlersVersion': {}, 'mimeTypes': {}, 'schemes': {'afirma': {'stubEntry': True}}}
with open('$ZEN_PROFILE/handlers.json', 'w') as f:
    json.dump(d, f)
"
    ok "handlers.json creado (no existía)"
fi

# ── PASO 9: Instalar el CA en el cert9.db del perfil de Zen ────
log "Paso 9: Instalar CA en cert9.db del perfil de Zen"
# IMPORTANTE: usar $HOME (no /tmp), el /tmp del sandbox es privado
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp "$ZEN_PROFILE/cert9.db"   "$WORK_DIR/cert9.db"
cp "$ZEN_PROFILE/key4.db"    "$WORK_DIR/key4.db"
cp "$ZEN_PROFILE/pkcs11.txt" "$WORK_DIR/pkcs11.txt"

# Borrar CA viejo si existía y reinstalar con CT,C,C (CA SSL + S/MIME + JAR)
flatpak run --command=sh "$AFIRMA_APP" -c "
    certutil -d sql:$WORK_DIR -D -n SocketAutoFirma 2>/dev/null || true
    certutil -d sql:$WORK_DIR -A -n SocketAutoFirma \
             -i $CA_CER \
             -t CT,C,C
"
# Verificar
if flatpak run --command=sh "$AFIRMA_APP" -c \
    "certutil -L -d sql:$WORK_DIR 2>/dev/null | grep -i Autofirma" ; then
    ok "CA instalado en workspace intermedio"
else
    warn "No se pudo instalar el CA; verifique los logs"
fi

cp "$WORK_DIR/cert9.db"  "$ZEN_PROFILE/cert9.db"
cp "$WORK_DIR/key4.db"   "$ZEN_PROFILE/key4.db"
rm -rf "$WORK_DIR"
ok "CA copiado al perfil de Zen"

# ── PASO 10: Instalar el CA en NSS DB de Chrome (opcional) ────
log "Paso 10: Instalar CA en ~/.pki/nssdb (para Chrome/Chromium)"
mkdir -p "$NSS_DB"
flatpak run --command=sh "$AFIRMA_APP" -c "
    certutil -d sql:$NSS_DB -D -n SocketAutoFirma 2>/dev/null || true
    certutil -d sql:$NSS_DB -A -n SocketAutoFirma \
             -i $CA_CER \
             -t CT,C,C
" || warn "No se pudo actualizar la NSS DB de Chrome"
ok "NSS DB de Chrome actualizada"

# ── PASO 11: Matar procesos antiguos ──────────────────────────
log "Paso 11: Matar procesos antiguos de AutoFirma"
pkill -f "autofirma.jar" 2>/dev/null || true
rm -f "$ZEN_PROFILE/lock" 2>/dev/null || true
ok "Limpieza completada"

echo ""
echo "================================================================"
echo " ✅  INSTALACIÓN COMPLETADA"
echo "================================================================"
echo ""
echo " Pasos finales:"
echo "   1. Cierra Zen Browser completamente (mata también todos"
echo "      sus procesos:  pkill -f app.zen_browser.zen"
echo "   2. Abre Zen Browser."
echo "   3. Prueba a firmar en VEA:"
echo ""
echo "      https://veaja.cloud.juntadeandalucia.es/inicio/"
echo ""
echo " Si algo va mal, mira el README.md -> Diagnóstico."
echo ""