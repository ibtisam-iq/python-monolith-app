# Codebase Modernization

Before doing any DevOps work, I audited and modernized the inherited Python Flask codebase to make it pipeline-ready, container-ready, and production-grade. This document covers every change made, the problem it solved, and the reasoning behind it.

---

## `requirements.txt` — Pinned All Dependencies

The original file had unpinned or loosely versioned dependencies — a pipeline reliability risk. If a pipeline runs `pip install flask` today and again in three months, it may silently get a different version, breaking the build in ways that are hard to reproduce.

I pinned every package to an exact version for fully reproducible builds across all environments — developer laptop, CI runner, and production container.

| Package | Change | Why |
|---|---|---|
| `Flask`, `Flask-SQLAlchemy`, `SQLAlchemy`, `psycopg2-binary` | Pinned to latest stable | Reproducible builds across all environments |
| `gunicorn` | Added (was missing) | Required by `Dockerfile` CMD — production WSGI server |
| `pytest` | Added (was missing) | Required to run the test suite |
| `python-dotenv` | Added (was missing) | Auto-loads `.env` in `run.py` and `conftest.py` |
| All transitive deps | Added and pinned | `blinker`, `click`, `greenlet`, `itsdangerous`, `Jinja2`, `MarkupSafe`, `Werkzeug`, `typing_extensions` |

> **Why pin transitive dependencies?** A package like `Flask` depends on `Werkzeug` at runtime. If `Werkzeug` is not pinned in `requirements.txt`, pip may silently upgrade it to a version that breaks Flask compatibility. Pinning the full dependency tree — including transitive packages — makes every build byte-for-byte identical.

---

## `config.py` — Removed Hardcoded DB Fallback

The original code had a hardcoded fallback:

```python
# BEFORE — original code
DATABASE_URL = os.environ.get('DATABASE_URL', 'postgresql://root:root@localhost/my_database')
```

This is dangerous in two ways:
1. **Silent misconfiguration** — if `DATABASE_URL` is not set, the app silently connects to `root:root@localhost` instead of failing loudly. In a CI/CD pipeline or a production container, this results in a connection error that is far harder to debug than a clear `EnvironmentError` at startup.
2. **Credential leakage** — hardcoded credentials in source code are a security risk, even if they are only defaults.

I removed the fallback entirely. `DATABASE_URL` is now read exclusively from the environment:

```python
# AFTER — environment-only
DATABASE_URL = os.environ.get('DATABASE_URL')
```

A `validate()` method raises a clear `EnvironmentError` at app startup (not at import time) if the variable is unset:

```python
@staticmethod
def validate():
    if not Config.SQLALCHEMY_DATABASE_URI:
        raise EnvironmentError(
            "DATABASE_URL environment variable is not set. "
            "Copy .env.example to .env and fill in the values."
        )
```

> **Why not raise at import time?** If `validate()` fired on module import, pytest would fail to import `models.py` and `routes.py` unless `DATABASE_URL` was set — even for tests that mock the database and never make a real connection. Placing the check inside `create_app()` means pytest can import freely; the validation only runs when the Flask app actually starts.

---

## `app/__init__.py` — Runtime Validation

Moved `Config.validate()` call inside `create_app()` so the environment check only fires when the Flask application factory is invoked — not during module import.

```python
def create_app():
    app = Flask(__name__)
    Config.validate()   # <-- fires here, not at import
    app.config.from_object(Config)
    db.init_app(app)
    ...
```

This cleanly separates two concerns:
- **Import time** — models and routes can be imported by pytest, linters, and documentation tools without a database.
- **Runtime** — when the server actually starts, `DATABASE_URL` must be set or the process exits immediately with a clear message.

---

## `run.py` — Auto-Loads `.env`

Added `python-dotenv` to auto-load `.env` at startup:

```python
from dotenv import load_dotenv
load_dotenv()
```

Without this, a developer would need to manually `export` each variable or run `source .env` before starting the app — easy to forget, and inconsistent across shells. With `load_dotenv()`, running `python run.py` just works.

> **Note:** In the Docker container, `.env` is not present (excluded via `.dockerignore`). All environment variables are injected by Docker Compose or Kubernetes at runtime. `load_dotenv()` is a no-op when no `.env` file exists — it does not raise an error.

---

## `tests/conftest.py` — New File

pytest automatically runs `conftest.py` before collecting any tests. This file loads `.env` so `DATABASE_URL` is available for tests that need it:

```python
from dotenv import load_dotenv
load_dotenv()
```

Tests that mock the database continue to work without a real connection. Tests that need the real database get `DATABASE_URL` from `.env` without any manual setup.

> **Why not just set `DATABASE_URL` in each test?** `conftest.py` runs once per session, before any test is collected. It is the correct place for session-level environment setup in pytest — not individual test files.

---

## `.env.example` — New File

Added an environment variable template that is safe to commit to version control:

```env
POSTGRES_USER=your_db_user
POSTGRES_PASSWORD=your_db_password
POSTGRES_DB=flask_db
DATABASE_URL=postgresql://your_db_user:your_db_password@localhost:5432/flask_db
PORT=5000
```

Developers copy it to `.env` and fill in real values. `.env` itself is excluded from version control via `.gitignore`. This pattern is standard across all modern applications — it documents what variables exist and what format they expect, without exposing real credentials.

> **Note:** Write `DATABASE_URL` with literal values, not `${...}` shell variables — bash substitution does not work when loading `.env` with `python-dotenv`. Use `localhost` for bare-metal runs. For Docker Compose, `DATABASE_URL` is overridden in `compose.yml` to use `postgres` (the PostgreSQL service name) as the hostname.

---

## `app/routes.py` — Added `/health` Route

I added a `/health` endpoint to `routes.py`. This was not in the original codebase and is entirely a DevOps addition — required for Docker `HEALTHCHECK`, Docker Compose `healthcheck`, and Kubernetes liveness/readiness probes.

```python
@main.route('/health')
def health():
    """
    Liveness/readiness probe endpoint.
    Used by Docker HEALTHCHECK, Kubernetes liveness and readiness probes,
    and docker compose healthcheck.
    Returns 200 OK if the app is running and the database is reachable.
    """
    try:
        db.session.execute(db.text('SELECT 1'))
        return jsonify(status='healthy', database='reachable'), 200
    except Exception as e:
        return jsonify(status='unhealthy', error=str(e)), 503
```

### Why a dedicated `/health` route?

A process health check and an application health check are two different things:

| What is checked | What it tells you |
|---|---|
| Process is running (`ps aux`) | The container has not crashed — but the app may be deadlocked or DB-disconnected |
| Port is open (`tcp://app:5000`) | The network stack is responding — but the app may be returning 500s |
| `GET /health` returns 200 | The app is running **and** the database is reachable |

Without a `/health` route, `HEALTHCHECK` in the Dockerfile can only check if the port is open — which is a weaker signal. The route runs `SELECT 1` against the database on every probe, so a broken DB connection surfaces immediately as a `503` instead of silently allowing unhealthy containers to receive traffic.

### Response format

**Healthy (200):**
```json
{"database": "reachable", "status": "healthy"}
```

**Unhealthy (503):**
```json
{"error": "connection refused", "status": "unhealthy"}
```

The `503 Service Unavailable` status code is correct here — it tells load balancers, Kubernetes, and Docker to stop routing traffic to this instance.

### How it is used across the stack

**Dockerfile `HEALTHCHECK`:**
```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT:-5000}/health')"
```

Uses Python's built-in `urllib` — no `curl` or `wget` dependency needed in the slim runtime image.

**`compose.yml` app service healthcheck:**
```yaml
healthcheck:
  test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```

**Kubernetes probes (`deployment.yaml`):**
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 60
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

> **Liveness vs Readiness in Kubernetes:**
> - `livenessProbe` — if this fails, Kubernetes **restarts** the container. Use it to detect deadlocks.
> - `readinessProbe` — if this fails, Kubernetes **removes the pod from the Service endpoints** (stops routing traffic) but does not restart it. Use it to detect temporary unavailability (e.g., DB connection not yet established on startup).

### Verify manually

```bash
# Bare-metal or Docker Compose
curl http://localhost:5000/health

# Inside the running container
docker exec <container_id> python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:5000/health').read())"
```
