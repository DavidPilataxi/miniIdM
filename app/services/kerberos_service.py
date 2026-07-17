import subprocess
import tempfile
import os

from config import KADMIN_KEYTAB, KADMIN_PRINCIPAL


def autenticar(usuario, password):
    with tempfile.NamedTemporaryFile(delete=False) as ccache:
        ccache_path = ccache.name

    env = os.environ.copy()
    env["KRB5CCNAME"] = f"FILE:{ccache_path}"

    try:
        proceso = subprocess.run(
            ["kinit", usuario],
            input=password + "\n",
            capture_output=True,
            text=True,
            env=env,
            timeout=5
        )

        if proceso.returncode == 0:
            subprocess.run(["kdestroy"], env=env)
            return True, None

        return False, proceso.stderr.strip()
    finally:
        if os.path.exists(ccache_path):
            os.unlink(ccache_path)


def _kadmin_remoto(comando):
    """Ejecuta un comando kadmin contra el admin_server remoto (kdc1),
    autenticado con el keytab de servicio svc-admin/admin. No requiere
    sudo ni acceso local a la base de datos del KDC."""
    proceso = subprocess.run(
        [
            "kadmin",
            "-k", "-t", KADMIN_KEYTAB,
            "-p", KADMIN_PRINCIPAL,
            "-q", comando
        ],
        capture_output=True,
        text=True,
        timeout=10
    )
    return proceso


def crear_principal(uid, password):
    comando = f'addprinc -pw {password} {uid}'
    proceso = _kadmin_remoto(comando)
    exito = "created" in proceso.stdout.lower() or proceso.returncode == 0
    error = None if exito else (proceso.stderr.strip() or proceso.stdout.strip())
    return exito, error


def eliminar_principal(uid):
    comando = f'delprinc -force {uid}'
    proceso = _kadmin_remoto(comando)
    exito = proceso.returncode == 0
    error = None if exito else (proceso.stderr.strip() or proceso.stdout.strip())
    return exito, error