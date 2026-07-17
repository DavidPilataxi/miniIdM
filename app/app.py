from app import create_app
from config import APP_HOST, APP_PORT

app = create_app()

if __name__ == "__main__":
    app.run(
        host=APP_HOST,
        port=APP_PORT,
        debug=False,
        ssl_context=(
            "/opt/pki/certs/webserver.crt",
            "/opt/pki/certs/webserver.key"
        )
    )