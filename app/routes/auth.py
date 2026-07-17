from flask import Blueprint
from flask import render_template
from flask import request
from flask import redirect
from flask import session

from app.services.kerberos_service import autenticar
from app.services.ldap_service import buscar_usuario

auth_bp = Blueprint("auth", __name__)


@auth_bp.route("/")
def index():

    if "usuario" in session:
        return redirect("/home")

    return redirect("/login")


@auth_bp.route("/login", methods=["GET", "POST"])
def login():

    if request.method == "POST":

        usuario = request.form["usuario"]
        password = request.form["password"]

        ok, _ = autenticar(usuario, password)

        if ok:

            datos = buscar_usuario(usuario)

            if datos:

                session["usuario"] = datos

                return redirect("/home")

        return render_template(
            "login.html",
            error="Usuario o contraseña incorrectos."
        )

    return render_template("login.html")


@auth_bp.route("/logout")
def logout():

    session.clear()

    return redirect("/login")