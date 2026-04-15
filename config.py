import os

class Config:
    # Reads DATABASE_URL exclusively from the environment.
    # No hardcoded fallback — if unset at app startup, a clear error is raised.
    # Set this variable in your .env file or Docker Compose environment block.
    # Example value: postgresql://user:password@db_host:5432/db_name
    # Run: cp .env.example .env  — then fill in your actual values.
    SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL')
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    @staticmethod
    def validate():
        if not os.environ.get('DATABASE_URL'):
            raise EnvironmentError(
                "DATABASE_URL environment variable is not set. "
                "Copy .env.example to .env and fill in your values before running."
            )
