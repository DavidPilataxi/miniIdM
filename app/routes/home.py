from flask import Blueprint
from flask import render_template
from flask import redirect
from flask import session

home_bp = Blueprint("home", __name__)


@home_bp.route("/home")
def home():

    if "usuario" not in session:
        return redirect("/login")

    return render_template(
        "home.html",
        usuario=session["usuario"]
    )