# Python Monolith Application

## Overview

This is a Python Flask-based monolithic student management web application serving as the **source codebase** for two downstream DevOps projects:

- **[DevSecOps Pipelines](https://github.com/ibtisam-iq/devsecops-pipelines)** — CI/CD pipelines that build, scan, and package this application into a secure, deployable artifact using Jenkins, GitHub Actions, Docker, SonarQube, and Trivy.
- **[Platform Engineering Systems](https://github.com/ibtisam-iq/platform-engineering-systems)** — Deployment workflows that run this artifact across Docker Compose, AWS EC2, EKS (Kubernetes), Terraform, and GitOps-based delivery.

> I did not build this application from scratch. As a DevOps Engineer, my focus is on everything that happens **around the code** — building, securing, packaging, and operating it in production-like environments.

---

## Application Structure

```
python-monolith-app/
├── app/
│   ├── __init__.py             # Application factory (create_app)
│   ├── models.py               # SQLAlchemy ORM models
│   ├── routes.py               # Route definitions and view logic
│   ├── static/                 # CSS, JS, images
│   └── templates/              # Jinja2 HTML templates
├── tests/
│   ├── conftest.py             # Loads .env before pytest collects tests
│   └── test_app.py             # Unit tests for Item model
├── config.py                   # Reads DATABASE_URL from environment; validates at startup
├── run.py                      # Entry point — loads .env, creates app, starts server
├── requirements.txt            # Pinned Python dependencies
├── .env.example                # Environment variable template
├── .gitignore                  # Excludes .env, .venv, __pycache__, etc.
├── Dockerfile
└── compose.yml
```

Two-tier architecture: Presentation + Business Logic (Flask — routes, templates, ORM) → Data (PostgreSQL).

> **Note:** This is a classic two-tier server-side rendered monolith. Flask handles both the UI (Jinja2 templates) and the application logic in one process — there is no decoupled frontend.

---

## Technology Stack

| Layer | Technology |
|---|---|
| Language | Python 3.12 |
| Framework | Flask 3.1 |
| ORM | Flask-SQLAlchemy + SQLAlchemy 2.0 |
| Database | PostgreSQL 16 |
| Templating | Jinja2 |
| WSGI Server | Gunicorn |
| Build Tool | pip + requirements.txt |

---

## DevOps Implementation Journey

### Step 0 — Codebase Modernization

Before doing any DevOps work, I audited and modernized the inherited codebase to make it pipeline-ready and production-grade.

#### `requirements.txt` — Pinned all dependencies

The original file had unpinned or loosely versioned dependencies — a pipeline reliability risk. I pinned every package to an exact version for fully reproducible builds.

| Package | Change | Why |
|---|---|---|
| `Flask`, `Flask-SQLAlchemy`, `SQLAlchemy`, `psycopg2-binary` | Pinned to latest stable | Reproducible builds across all environments |
| `gunicorn` | Added (was missing) | Required by `Dockerfile` CMD — production WSGI server |
| `pytest` | Added (was missing) | Required to run the test suite |
| `python-dotenv` | Added (was missing) | Auto-loads `.env` in `run.py` and `conftest.py` |
| All transitive deps | Added and pinned | `blinker`, `click`, `greenlet`, `itsdangerous`, `Jinja2`, `MarkupSafe`, `Werkzeug`, `typing_extensions` |

#### `config.py` — Removed hardcoded DB fallback

The original code had a hardcoded `postgresql://root:root@localhost/my_database` fallback. I removed it entirely. `DATABASE_URL` is now read exclusively from the environment. A `validate()` method raises a clear `EnvironmentError` at app startup (not at import time) if the variable is unset — so pytest can import models freely without triggering the error.

#### `app/__init__.py` — Runtime validation

Moved `Config.validate()` call inside `create_app()` so the environment check only fires when the Flask app actually starts — not during module import. This separates test imports from runtime requirements.

#### `run.py` — Auto-loads `.env`

Added `python-dotenv` to auto-load `.env` at startup. No need to manually `source .env` before running the app.

#### `tests/conftest.py` — New file

pytest auto-runs `conftest.py` before collecting tests. It loads `.env` so `DATABASE_URL` is available for any test that needs it, while tests that mock the DB continue to work without a real connection.

#### `.env.example` — New file

Added an environment variable template safe to commit. Documents all required variables with inline comments. Developers copy it to `.env` and fill in real values — `.env` itself is excluded from version control via `.gitignore`.

---

### Step 1 — Environment Standardization

All configuration is now driven by environment variables. No hardcoded values exist anywhere in the codebase.

```bash
# Copy the template and fill in real values
cp .env.example .env
```

Key variables in `.env`:

```env
POSTGRES_USER=your_db_user
POSTGRES_PASSWORD=your_db_password
POSTGRES_DB=flask_db
DATABASE_URL=postgresql://your_db_user:your_db_password@localhost:5432/flask_db
PORT=5000
```

> **Note:** Write `DATABASE_URL` with literal values, not `${...}` shell variables — bash substitution does not work when loading `.env` with `python-dotenv`. Use `localhost` for bare-metal runs. For Docker Compose, replace `localhost` with `db` (the PostgreSQL service name in `compose.yml`).

---

### Step 2 — Local Build & Validation

Before building any pipeline, I validated the full application lifecycle locally.

**Install and configure PostgreSQL:**

```bash
sudo apt update && sudo apt install -y postgresql postgresql-contrib
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Enter the postgres superuser shell
sudo -u postgres psql
```

```sql
CREATE DATABASE flask_db;
CREATE USER your_db_user WITH PASSWORD 'your_db_password';
GRANT ALL PRIVILEGES ON DATABASE flask_db TO your_db_user;
\c flask_db
GRANT ALL ON SCHEMA public TO your_db_user;
\q
```

> **Note (PostgreSQL 15+):** `GRANT ALL PRIVILEGES ON DATABASE` grants database-level rights only. In PostgreSQL 15+, you must also grant schema-level rights separately — otherwise the user cannot create tables. `\c flask_db` switches into the database before the schema grant.

**Verify PostgreSQL is running:**

```bash
sudo systemctl status postgresql
PGPASSWORD=your_db_password psql -U your_db_user -d flask_db -h 127.0.0.1 -c "\l" | grep flask_db
```

**Set up a virtual environment and install dependencies:**

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

**Run the test suite:**

```bash
pytest tests/
```

> 4 tests pass. The suite covers unit tests for the `Item` model — object creation, `__repr__`, and mocked query logic. No real database connection is required.

**Run the application:**

```bash
python run.py
```

App runs at: `http://localhost:5000`

---

### Step 3 — DevSecOps Pipelines (CI/CD)

With the application validated locally, I built automated pipelines to transform this code into a secure, deployable artifact.

Pipelines include: pip install → pytest → SonarQube analysis → Trivy vulnerability scan → Docker image build → Nexus artifact management → Jenkins & GitHub Actions automation.

👉 **Pipelines repository:** [DevSecOps Pipelines](https://github.com/ibtisam-iq/devsecops-pipelines/tree/main/pipelines/python-monolith)

---

### Step 4 — Platform Engineering (Deployment & Operations)

Once the artifact was ready, I deployed it using multiple industry-standard approaches.

Deployment targets: Local bare-metal · Docker Compose · AWS EC2 · EKS (Kubernetes) · Terraform-provisioned infrastructure.

Also covered: monitoring, observability, scaling strategies, and system reliability.

👉 **Platform repository:** [Platform Engineering Systems](https://github.com/ibtisam-iq/platform-engineering-systems/tree/main/systems/python-monolith)

---

## Key Idea

> Code = Input. Pipelines secure it. Infrastructure runs it.

| Repository | Role |
|---|---|
| **This repo** | Application source code — the single input to everything below |
| **[DevSecOps Pipelines](https://github.com/ibtisam-iq/devsecops-pipelines)** | CI/CD — builds, scans, and packages the code into a deployable artifact |
| **[Platform Engineering Systems](https://github.com/ibtisam-iq/platform-engineering-systems)** | Platform — deploys, operates, and scales the artifact across multiple targets |

This separation is intentional: one repo per concern. The source code stays clean, the pipeline logic stays auditable, and the deployment configs stay independently versioned.
