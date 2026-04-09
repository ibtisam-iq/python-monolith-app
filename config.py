import os

class Config:
    # Reads DATABASE_URL from the environment.
    # Set this variable in your .env file or Docker Compose environment block.
    # Example value: postgresql://user:password@db_host:5432/db_name
    # Falls back to a local default only when DATABASE_URL is not set (local dev without Docker).
    SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL') or \
        'postgresql://root:root@localhost/my_database'
    SQLALCHEMY_TRACK_MODIFICATIONS = False
