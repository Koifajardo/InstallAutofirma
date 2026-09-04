#!/usr/bin/env python3
"""
Parche para handlers.json de Firefox/Zen Browser.

Configura el protocolo `afirma` como esquema delegado al handler del
sistema usando el formato `stubEntry` (igual que `mailto`).

IMPORTANTE (sep 2026): el formato `{"action": 3}` que se usaba antes
funcionaba en Zen 1.21.8b, pero en Zen >= 1.21.16b (base Firefox nueva)
un valor de `action` en un esquema produce un FALLO SILENCIOSO: el
navegador no lanza AutoFirma y no muestra diálogo ni error. El formato
correcto es `{"stubEntry": true}`.

Uso:
    python3 handlers.json.patch.py /ruta/al/handlers.json
"""
import json
import os
import sys


def patch(path: str) -> int:
    if not os.path.exists(path):
        # Si no existe, lo creamos mínimo
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = {
            "defaultHandlersVersion": {},
            "mimeTypes": {},
            "schemes": {"afirma": {"stubEntry": True}},
        }
        with open(path, "w") as f:
            json.dump(data, f)
        print(f"[INFO] handlers.json creado en {path}")
        return 0

    with open(path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            print(f"[FAIL] handlers.json inválido: {e}", file=sys.stderr)
            return 1

    schemes = data.setdefault("schemes", {})
    afirma = schemes.get("afirma", {})
    if afirma.get("stubEntry") is True and "action" not in afirma:
        print("[INFO] afirma:// ya estaba en stubEntry. Sin cambios.")
        return 0

    # Formato nuevo: stubEntry (delegado al sistema), sin "action" ni "ask"
    schemes["afirma"] = {"stubEntry": True}

    with open(path, "w") as f:
        json.dump(data, f, indent=None, separators=(",", ":"))
    print(f"[ OK ] handlers.json parcheado: afirma:// -> stubEntry en {path}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Uso: {sys.argv[0]} <ruta/handlers.json>", file=sys.stderr)
        sys.exit(2)
    sys.exit(patch(sys.argv[1]))
