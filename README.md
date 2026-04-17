# Python Monolith Application

## Overview

This is a Python Flask-based monolithic student management web application serving as the **source codebase** for two downstream DevOps projects:

- **[DevSecOps Pipelines](https://github.com/ibtisam-iq/devsecops-pipelines)** — CI/CD pipelines that build, scan, and package this application into a secure, deployable artifact using Jenkins, GitHub Actions, Docker, SonarQube, and Trivy.
- **[Platform Engineering Systems](https://github.com/ibtisam-iq/platform-engineering-systems)** — Deployment workflows that run this artifact across Docker Compose, AWS EC2, EKS (Kubernetes), Terraform, and GitOps-based delivery.

> I did not build this application from scratch. As a DevOps Engineer, my focus is on everything that happens **around the code** — building, securing, packaging, and operating it in production-like environments.

> The files I added to this repository are: `Dockerfile`, `compose.yml`, `.dockerignore`, and `.gitignore`. Everything else under `app/` belongs to the original developer.

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
├── docs/
│   ├── codebase-modernization.md   # Step 0 — full codebase audit and changes
│   ├── understand-architecture.md  # Deep-dive into app structure and design
│   └── understand-dockerization.md # Line-by-line Dockerfile and Compose rationale
├── config.py                   # Reads DATABASE_URL from environment; validates at startup
├── run.py                      # Entry point — loads .env, creates app, starts server
├── requirements.txt            # Pinned Python dependencies
├── Dockerfile                  # Multi-stage build: Python builder → slim runtime
├── compose.yml                 # Local containerized environment (app + PostgreSQL)
├── .dockerignore               # Excludes .venv, .env, __pycache__, tests/ from build context
├── .gitignore                  # Excludes .env, .venv, __pycache__, etc.
└── .env.example                # Environment variable template
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
| Containerization | Docker (multi-stage) + Docker Compose |

---

## DevOps Implementation Journey

### Step 0 — Codebase Modernization

Before doing any DevOps work, I audited and modernized the inherited codebase — fixing unpinned dependencies, removing hardcoded DB credentials, adding environment validation, and introducing a `/health` route for container probes.

> Full change log with rationale: [`docs/codebase-modernization.md`](docs/codebase-modernization.md)

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

> **Note:** Write `DATABASE_URL` with literal values, not `${...}` shell variables — bash substitution does not work when loading `.env` with `python-dotenv`. Use `localhost` for bare-metal runs. For Docker Compose, `DATABASE_URL` is overridden in `compose.yml` to use `postgres` (the PostgreSQL service name) as the hostname automatically.

---

### Step 2 — Local Build & Bare-Metal Validation

Before writing any Docker config, I validated the full application lifecycle locally — native PostgreSQL, native Python, no containers. This confirmed the app connected to the database correctly before any containerization layer was introduced.

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

**Verify PostgreSQL is running and the database exists:**

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

### Step 3 — Containerization (Docker)

With the application validated on bare metal, I wrote the `Dockerfile` and `compose.yml` from scratch. I read `requirements.txt`, `config.py`, `.env.example`, and `run.py` before writing a single line — to understand exactly what the image needed: Python version, exposed port, health endpoint, WSGI server, and environment variable strategy.

**Key decisions I made and documented:**

- Multi-stage build to keep the runtime image lean (~120MB vs ~900MB)
- Non-root user for CIS/Trivy compliance
- Gunicorn as the production WSGI server (replaces Flask's dev server)
- `exec gunicorn` as PID 1 for clean signal handling in containers
- `${PORT:-5000}` default fallback so the container runs without a `.env` file present
- Healthcheck timing tuned to Flask + PostgreSQL's actual cold-start duration

The full rationale for every line is in [`docs/understand-dockerization.md`](docs/understand-dockerization.md).

#### Validating with Docker Compose

After writing the files, I validated them end-to-end using Docker Compose — spinning up both PostgreSQL and the app as containers on a shared internal network, with no local PostgreSQL installation needed.

```bash
cp .env.example .env
# Fill in: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, DATABASE_URL, PORT

docker compose up --build
```

> `--build` forces the Docker image to be rebuilt from the `Dockerfile`. Omit it on subsequent runs if the source code has not changed.

**What happens in sequence:**
1. Docker builds the `python-monolith-app` image using the multi-stage `Dockerfile`
2. The `postgres` container (PostgreSQL 16) starts and runs its healthcheck (`pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}`)
3. The `app` container waits for the `postgres` healthcheck to pass (`condition: service_healthy`)
4. Flask connects to PostgreSQL using the service name `postgres` as the hostname (overrides `localhost` from `.env`)
5. The app becomes available at `http://localhost:5000`

**Verify the health endpoint:**

```bash
curl http://localhost:5000/health
# {"database": "reachable", "status": "healthy"}
```

**Stop and clean up:**

```bash
# Stop containers but keep the database volume
docker compose down

# Stop containers AND delete the database volume (full reset)
docker compose down -v
```

---

### Step 4 — DevSecOps Pipelines (CI/CD)

With the application validated both natively and in containers, I built automated pipelines to transform this code into a secure, deployable artifact.

Pipelines include: pip install → pytest → SonarQube analysis → Trivy vulnerability scan → Docker image build → Nexus artifact management → Jenkins & GitHub Actions automation.

👉 **Pipelines repository:** [DevSecOps Pipelines](https://github.com/ibtisam-iq/devsecops-pipelines/tree/main/pipelines/python-monolith)

---

### Step 5 — Platform Engineering (Deployment & Operations)

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
