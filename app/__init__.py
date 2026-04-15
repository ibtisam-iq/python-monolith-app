from flask import Flask
from config import Config
from app.models import db  # Single source of truth for db — defined in models.py

def create_app():
    # Validate required environment variables at app startup — not at import time.
    # This allows pytest to import models without a real DATABASE_URL set.
    Config.validate()

    app = Flask(__name__)
    app.config.from_object(Config)

    # Register the SAME db instance that models.py and routes.py use.
    # Previously a second db = SQLAlchemy() was created here — that caused
    # RuntimeError: The current Flask app is not registered with this SQLAlchemy instance.
    db.init_app(app)

    from app.routes import main
    app.register_blueprint(main)

    with app.app_context():
        db.create_all()  # Create tables if they don't exist

    return app
