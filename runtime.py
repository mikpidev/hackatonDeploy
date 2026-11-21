"""Puntos de entrada para systemd. El código funcional pertenece al repo dogcode."""
import os
import re
import subprocess
from pathlib import Path


def api():
    from starlette.middleware.trustedhost import TrustedHostMiddleware
    from app import main

    # El motor de escritorio solo permite localhost. Conservar esa protección y
    # añadir únicamente el dominio HTTPS servido por nuestro proxy.
    domain = os.environ["DOGCODE_DOMAIN"]
    trusted = next(m for m in main.app.user_middleware if m.cls is TrustedHostMiddleware)
    trusted.kwargs["allowed_hosts"] = [*trusted.kwargs["allowed_hosts"], domain]
    main.ORIGEN_LOCAL = re.compile(f"(?:{main.ORIGEN_LOCAL.pattern}|{re.escape('https://' + domain)})")
    return main.app


def ibmi():
    from app.ibmi_prueba import crear_app

    secrets = Path(os.environ["CREDENTIALS_DIRECTORY"])
    creds = {env: (secrets / file).read_text().rstrip("\r\n")
             for env, file in [("DOGCODE_USUARIO", "usuario"), ("DOGCODE_PASSWORD", "password")]}
    if not all(creds.values()):
        raise RuntimeError("Faltan credenciales IBM i")
    cp = os.pathsep.join(["/opt/dogcode/current/jdbc", "/etc/dogcode/jt400.jar"])

    def insertar(campos):
        return subprocess.run(
            ["java", "-Djava.awt.headless=true", "-cp", cp, "InsertarSaldo"],
            env={**os.environ, **creds}, input="\n".join(campos) + "\n",
            encoding="utf-8", timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode

    return crear_app(insertar)
