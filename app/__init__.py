from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from config import Config

db = SQLAlchemy()

def create_app():
    # Validate required environment variables at app startup — not at import time.
    # This allows pytest to import models without a real DATABASE_URL set.
    Config.validate()

    app = Flask(__name__)
    app.config.from_object(Config)

    db.init_app(app)

    from app.routes import main
    app.register_blueprint(main)

    with app.app_context():
        db.create_all()  # Create tables if they don't exist

    return app
