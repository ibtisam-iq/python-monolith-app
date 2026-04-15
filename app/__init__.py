from flask import Flask
from .models import db
from config import Config  # Import Config class — do NOT hardcode DB URI here

def create_app():
    app = Flask(__name__)

    # Load all config (DATABASE_URL, TRACK_MODIFICATIONS, etc.) from Config class.
    # Config reads DATABASE_URL exclusively from the environment.
    # Raises EnvironmentError if DATABASE_URL is not set — no fallback.
    # To set: define DATABASE_URL in your .env file or Docker Compose environment block.
    app.config.from_object(Config)

    db.init_app(app)

    from .routes import main
    app.register_blueprint(main)

    with app.app_context():
        db.create_all()  # Create tables if they don't exist

    return app
