from flask import Flask

from config import SECRET_KEY

from app.routes.auth import auth_bp
from app.routes.home import home_bp
from app.routes.admin import admin_bp


def create_app():

    app = Flask(__name__)
    app.secret_key = SECRET_KEY

    app.register_blueprint(auth_bp)
    app.register_blueprint(home_bp)
    app.register_blueprint(admin_bp)

    return app
