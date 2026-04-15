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
├── tests/                      # Unit and integration tests
├── config.py                   # Reads DATABASE_URL from environment
├── run.py                      # Entry point — creates app, starts server
├── requirements.txt            # Pinned Python dependencies
├── .env.example                # Environment variable template
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

### Step 0 — Codebase Modernization (`requirements.txt`)

The inherited codebase was functional but had unpinned or loosely versioned dependencies. Before doing any DevOps work, I audited `requirements.txt` and pinned all dependencies to exact versions to ensure fully reproducible builds across all environments.

> **Note:** I used **AI-assisted analysis (Perplexity Pro)** to audit the dependency tree, verify compatibility between Flask, SQLAlchemy, and psycopg2-binary, and determine the correct pinned versions.

**Changes made to `requirements.txt`:**

| Package | Before | After | Why |
|---|---|---|---|
| `Flask` | Unpinned / loose | `3.1.3` | Latest stable; pinned for reproducibility |
| `Flask-SQLAlchemy` | Unpinned / loose | `3.1.1` | Compatible with SQLAlchemy 2.x |
| `SQLAlchemy` | Unpinned / loose | `2.0.49` | SQLAlchemy 2.x is the current LTS with async support |
| `psycopg2-binary` | Unpinned / loose | `2.9.11` | Latest stable PostgreSQL adapter |
| `gunicorn` | Missing | `23.0.0` | Required by `Dockerfile` CMD — production WSGI server |
| `pytest` | Missing | `8.3.5` | Required to run the test suite |
| All transitive deps | Absent | Pinned | `blinker`, `click`, `greenlet`, `itsdangerous`, `Jinja2`, `MarkupSafe`, `Werkzeug`, `typing_extensions` all pinned for full reproducibility |

---

### Step 1 — Environment Standardization

The original codebase had a hardcoded database URL fallback directly in `config.py`. I refactored it to read all configuration exclusively from environment variables, making it portable across all environments.

```bash
# Copy the template and fill in real values
cp .env.example .env
```

Key variables set in `.env`:

```env
POSTGRES_USER=your_db_user
POSTGRES_PASSWORD=your_db_password
POSTGRES_DB=flask_db
DATABASE_URL=postgresql://your_db_user:your_db_password@localhost:5432/flask_db
PORT=5000
```

> **Note:** The `DATABASE_URL` above uses `localhost` for local bare-metal runs. For Docker Compose, replace `localhost` with `db` — the PostgreSQL service name defined in `compose.yml`. Docker Compose resolves service names as hostnames on the internal network.

---

### Step 2 — Local Build & Validation

Before building any pipeline, I validated the full application lifecycle locally.

**Install and configure PostgreSQL:**

```bash
sudo apt update && sudo apt install -y postgresql postgresql-contrib
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Create DB user and database
sudo -u postgres psql
```

```sql
CREATE DATABASE flask_db;
CREATE USER your_db_user WITH PASSWORD 'your_db_password';
GRANT ALL PRIVILEGES ON DATABASE flask_db TO your_db_user;
\q
```

**Verify PostgreSQL is running and the database exists:**

```bash
# Check PostgreSQL is running
sudo systemctl status postgresql

# Confirm the database exists
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

> The test suite covers unit tests for the `Item` model — object creation, `__repr__`, and mocked query logic. No database connection is required to run these tests.

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
