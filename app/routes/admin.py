import re
from flask import Blueprint, render_template, request, redirect, session, url_for
from app.services.ldap_service import (
    listar_usuarios, crear_usuario_ldap, editar_usuario_ldap, eliminar_usuario_ldap, buscar_usuario
)
from app.services.kerberos_service import crear_principal, eliminar_principal

admin_bp = Blueprint("admin", __name__)

EMAIL_REGEX = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
UID_REGEX = re.compile(r"^[a-z][a-z0-9]{2,15}$")


def _requiere_admin():
    usuario = session.get("usuario")
    return usuario is not None and usuario.get("rol") == "admin"


def _validar_nuevo_usuario(uid, nombre, apellido, correo, password, rol):
    if not all([uid, nombre, apellido, correo, password]):
        return "Todos los campos son obligatorios."
    if not UID_REGEX.match(uid):
        return "El usuario debe tener 3-16 caracteres, minúsculas y números, iniciando con letra."
    if not EMAIL_REGEX.match(correo):
        return "El correo no tiene un formato válido."
    if len(password) < 6:
        return "La contraseña debe tener al menos 6 caracteres."
    if rol not in ("admin", "user"):
        return "Rol inválido."
    if buscar_usuario(uid):
        return f"El usuario '{uid}' ya existe."
    return None


def _validar_edicion(nombre, correo, rol):
    if not all([nombre, correo]):
        return "Nombre y correo son obligatorios."
    if not EMAIL_REGEX.match(correo):
        return "El correo no tiene un formato válido."
    if rol not in ("admin", "user"):
        return "Rol inválido."
    return None


@admin_bp.route("/usuarios")
def usuarios():
    if not _requiere_admin():
        return redirect(url_for("auth.login"))
    return render_template("usuarios.html", usuarios=listar_usuarios())


@admin_bp.route("/usuarios/nuevo", methods=["GET", "POST"])
def nuevo_usuario():
    if not _requiere_admin():
        return redirect(url_for("auth.login"))

    if request.method == "POST":
        uid = request.form.get("uid", "").strip()
        nombre = request.form.get("nombre", "").strip()
        apellido = request.form.get("apellido", "").strip()
        correo = request.form.get("correo", "").strip()
        password = request.form.get("password", "")
        rol = request.form.get("rol", "")

        error = _validar_nuevo_usuario(uid, nombre, apellido, correo, password, rol)
        if error:
            return render_template("usuario_form.html", error=error, modo="crear")

        ok_ldap, err_ldap = crear_usuario_ldap(uid, nombre, apellido, correo, rol)
        if not ok_ldap:
            return render_template("usuario_form.html", error=f"Error en LDAP: {err_ldap}", modo="crear")

        ok_krb, err_krb = crear_principal(uid, password)
        if not ok_krb:
            eliminar_usuario_ldap(uid)
            return render_template("usuario_form.html", error=f"Error en Kerberos: {err_krb}", modo="crear")

        return redirect(url_for("admin.usuarios"))

    return render_template("usuario_form.html", modo="crear")


@admin_bp.route("/usuarios/editar/<uid>", methods=["GET", "POST"])
def editar_usuario(uid):
    if not _requiere_admin():
        return redirect(url_for("auth.login"))

    if request.method == "POST":
        nombre = request.form.get("nombre", "").strip()
        correo = request.form.get("correo", "").strip()
        rol = request.form.get("rol", "")

        error = _validar_edicion(nombre, correo, rol)
        if error:
            return render_template("usuario_form.html", error=error, modo="editar", usuario={"uid": uid, "nombre": nombre, "correo": correo, "rol": rol})

        ok, err = editar_usuario_ldap(uid, nombre, correo, rol)
        if not ok:
            return render_template("usuario_form.html", error=f"Error: {err}", modo="editar", usuario={"uid": uid, "nombre": nombre, "correo": correo, "rol": rol})

        return redirect(url_for("admin.usuarios"))

    datos = buscar_usuario(uid)
    if not datos:
        return redirect(url_for("admin.usuarios"))

    return render_template("usuario_form.html", modo="editar", usuario=datos)


@admin_bp.route("/usuarios/eliminar/<uid>", methods=["POST"])
def eliminar_usuario(uid):
    if not _requiere_admin():
        return redirect(url_for("auth.login"))

    eliminar_principal(uid)
    eliminar_usuario_ldap(uid)

    return redirect(url_for("admin.usuarios"))