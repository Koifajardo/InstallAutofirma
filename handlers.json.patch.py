#!/usr/bin/env python3
"""
Parche para handlers.json de Firefox/Zen Browser.

Cambia la acción del protocolo `afirma` a `action: 3` (usar el handler por
defecto del sistema), para que Firefox/Zen abra AutoFirma vía xdg-open.

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
            "schemes": {"afirma": {"action": 3}},
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
    if afirma.get("action") == 3:
        print("[INFO] afirma:// ya estaba en action=3. Sin cambios.")
        return 0

    afirma["action"] = 3
    afirma.pop("ask", None)  # quitar flag ask:true si existía
    schemes["afirma"] = afirma

    with open(path, "w") as f:
        json.dump(data, f, indent=None, separators=(",", ":"))
    print(f"[ OK ] handlers.json parcheado: afirma:// -> action=3 en {path}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Uso: {sys.argv[0]} <ruta/handlers.json>", file=sys.stderr)
        sys.exit(2)
    sys.exit(patch(sys.argv[1]))