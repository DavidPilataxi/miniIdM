from ldap3 import Server, Connection, Tls, ALL_ATTRIBUTES, MODIFY_REPLACE
import ssl
from config import LDAP_SERVER, BASE_DN, CA_CERT_PATH, LDAP_ADMIN_DN, LDAP_ADMIN_PASSWORD


def _conexion_lectura():
    tls = Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=CA_CERT_PATH)
    server = Server(LDAP_SERVER, use_ssl=True, tls=tls)
    return Connection(server, auto_bind=True)


def _conexion_admin():
    tls = Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=CA_CERT_PATH)
    server = Server(LDAP_SERVER, use_ssl=True, tls=tls)
    conn = Connection(server, user=LDAP_ADMIN_DN, password=LDAP_ADMIN_PASSWORD, auto_bind=True)
    return conn


def buscar_usuario(uid):
    conn = _conexion_lectura()
    conn.search(
        search_base=f"ou=People,{BASE_DN}",
        search_filter=f"(uid={uid})",
        attributes=["uid", "cn", "sn", "mail", "employeeType"]
    )

    if not conn.entries:
        conn.unbind()
        return None

    usuario = conn.entries[0]
    rol = "user"
    if hasattr(usuario, "employeeType") and usuario.employeeType.value:
        rol = str(usuario.employeeType.value)

    datos = {
        "uid": str(usuario.uid),
        "nombre": str(usuario.cn),
        "correo": str(usuario.mail),
        "rol": rol
    }
    conn.unbind()
    return datos


def listar_usuarios():
    conn = _conexion_lectura()
    conn.search(
        search_base=f"ou=People,{BASE_DN}",
        search_filter="(objectClass=inetOrgPerson)",
        attributes=["uid", "cn", "mail", "employeeType"]
    )

    usuarios = []
    for entry in conn.entries:
        rol = "user"
        if hasattr(entry, "employeeType") and entry.employeeType.value:
            rol = str(entry.employeeType.value)
        usuarios.append({
            "uid": str(entry.uid),
            "nombre": str(entry.cn),
            "correo": str(entry.mail),
            "rol": rol
        })
    conn.unbind()
    return usuarios


def crear_usuario_ldap(uid, nombre, apellido, correo, rol):
    conn = _conexion_admin()

    # siguiente uidNumber/gidNumber disponible (simple, suficiente para el lab)
    conn.search(f"ou=People,{BASE_DN}", "(objectClass=posixAccount)", attributes=["uidNumber"])
    existentes = [int(e.uidNumber.value) for e in conn.entries] or [20000]
    siguiente_uid = max(existentes) + 1

    dn = f"uid={uid},ou=People,{BASE_DN}"
    atributos = {
        "objectClass": ["inetOrgPerson", "posixAccount", "shadowAccount"],
        "cn": f"{nombre} {apellido}",
        "sn": apellido,
        "uid": uid,
        "uidNumber": str(siguiente_uid),
        "gidNumber": "10001",
        "homeDirectory": f"/home/{uid}",
        "loginShell": "/bin/bash",
        "mail": correo,
        "employeeType": rol
    }

    ok = conn.add(dn, attributes=atributos)
    error = conn.result if not ok else None
    conn.unbind()
    return ok, error


def editar_usuario_ldap(uid, nombre, correo, rol):
    conn = _conexion_admin()
    dn = f"uid={uid},ou=People,{BASE_DN}"

    cambios = {
        "cn": [(MODIFY_REPLACE, [nombre])],
        "mail": [(MODIFY_REPLACE, [correo])],
        "employeeType": [(MODIFY_REPLACE, [rol])]
    }

    ok = conn.modify(dn, cambios)
    error = conn.result if not ok else None
    conn.unbind()
    return ok, error


def eliminar_usuario_ldap(uid):
    conn = _conexion_admin()
    dn = f"uid={uid},ou=People,{BASE_DN}"
    ok = conn.delete(dn)
    error = conn.result if not ok else None
    conn.unbind()
    return ok, error