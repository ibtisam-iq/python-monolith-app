from flask import Flask
from .models import db
from config import Config  # Import Config class — do NOT hardcode DB URI here

def create_app():
    app = Flask(__name__)

    # Load all config (DATABASE_URL, TRACK_MODIFICATIONS, etc.) from Config class.
    # Config reads DATABASE_URL from the environment first; falls back to localhost default.
    # To override: set the DATABASE_URL environment variable (e.g. in .env or Docker Compose).
    app.config.from_object(Config)

    db.init_app(app)

    from .routes import main
    app.register_blueprint(main)

    with app.app_context():
        db.create_all()  # Create tables if they don't exist

    return app
