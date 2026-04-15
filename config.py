import os

class Config:
    # Reads DATABASE_URL exclusively from the environment.
    # Raises EnvironmentError if DATABASE_URL is not set — no hardcoded fallback.
    # Set this variable in your .env file or Docker Compose environment block.
    # Example value: postgresql://user:password@db_host:5432/db_name
    # Run: cp .env.example .env  — then fill in your actual values.
    _db_url = os.environ.get('DATABASE_URL')
    if not _db_url:
        raise EnvironmentError(
            "DATABASE_URL environment variable is not set. "
            "Copy .env.example to .env and fill in your values before running."
        )
    SQLALCHEMY_DATABASE_URI = _db_url
    SQLALCHEMY_TRACK_MODIFICATIONS = False
