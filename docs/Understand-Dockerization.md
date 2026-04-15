# Understand Dockerization — Python Flask + PostgreSQL

This document explains **how to Dockerize any Python Flask application** from scratch.
Everything here is derived from the real decisions made in this project — including
what worked, what failed, and why each choice was made.

---

## Table of Contents

1. [The Big Picture — What Dockerization Means](#1-the-big-picture)
2. [Understand the Project Before Writing a Single Line](#2-understand-the-project-first)
3. [The Dockerfile — Line by Line](#3-the-dockerfile)
4. [Multi-Stage Builds — Why and How](#4-multi-stage-builds)
5. [psycopg2 vs psycopg2-binary — A Critical Distinction](#5-psycopg2-vs-psycopg2-binary)
6. [Non-Root User — Security Inside Containers](#6-non-root-user)
7. [gunicorn — Why Not Flask's Built-in Server](#7-gunicorn)
8. [Environment Variables Strategy](#8-environment-variables-strategy)
9. [docker compose — Orchestrating Multiple Containers](#9-docker-compose)
10. [Networking — How Containers Talk to Each Other](#10-networking)
11. [Healthchecks — Why depends_on Alone is Not Enough](#11-healthchecks)
12. [Volumes — Persisting Database Data](#12-volumes)
13. [.dockerignore — What NOT to Copy](#13-dockerignore)
14. [The SQLAlchemy Pitfall — Duplicate db Instances](#14-the-sqlalchemy-pitfall)
15. [Mental Model — Bare-Metal vs Docker Compose](#15-mental-model)
16. [Quick Reference — Commands](#16-quick-reference)

---

## 1. The Big Picture

Dockerization means packaging your application and all its dependencies into a
**container image** — a portable, reproducible unit that runs identically on any
machine regardless of what is installed on the host.

For a Flask + PostgreSQL app, Dockerization involves:

- A **Dockerfile** — instructions to build the Flask app image
- A **compose.yml** — orchestrates the Flask app container AND a PostgreSQL container
  together, connecting them on a shared network
- An **.env file** — provides runtime configuration (credentials, URLs, ports)
  without hardcoding anything in source code

```
┌─────────────────────────────────────────────┐
│               Docker Host                   │
│                                             │
│  ┌──────────────┐      ┌─────────────────┐  │
│  │  flask-app   │─────▶│   postgres-db   │  │
│  │  (port 5000) │      │   (port 5432)   │  │
│  └──────────────┘      └─────────────────┘  │
│         │                      │            │
│         └──────────────────────┘            │
│                app-network                  │
└─────────────────────────────────────────────┘
```

---

## 2. Understand the Project First

Before writing a Dockerfile for ANY Python project, answer these questions:

| Question | This Project's Answer |
|---|---|
| What Python version? | 3.12 (check `runtime.txt` or `pyproject.toml` or `requirements.txt`) |
| What does the app need at runtime? | Flask, SQLAlchemy, gunicorn, psycopg2-binary |
| Does it need a database? | Yes — PostgreSQL |
| Does it need build tools to compile? | No — psycopg2-**binary** is pre-compiled |
| How is it started? | `python run.py` bare-metal, `gunicorn run:app` in production |
| What port does it listen on? | 5000 |
| What config does it need? | `DATABASE_URL`, `PORT` via environment variables |

Knowing these answers determines every decision in the Dockerfile.

---

## 3. The Dockerfile — Line by Line

```dockerfile
# Stage 1: Builder
FROM python:3.12-slim AS builder
```

`python:3.12-slim` is a Debian-based image with Python pre-installed but without
extra tools. `AS builder` names this stage — we reference it later in Stage 2.

```dockerfile
WORKDIR /app
```

Sets the working directory inside the container. All subsequent `COPY`, `RUN`,
`CMD` instructions operate relative to `/app`. Creates the directory if it doesn't exist.

```dockerfile
COPY requirements.txt .
RUN pip install --upgrade pip \
    && pip install --prefix=/install --no-cache-dir -r requirements.txt
```

**Why copy `requirements.txt` before the rest of the code?**
Docker builds in layers. If `requirements.txt` hasn't changed, Docker reuses the
cached layer and skips reinstalling dependencies — even if your application code
changed. This makes rebuilds significantly faster.

`--prefix=/install` installs packages into `/install` instead of the system Python.
This allows us to copy just the installed packages into Stage 2 cleanly.

`--no-cache-dir` tells pip not to cache downloaded packages — reduces image size.

---

## 4. Multi-Stage Builds

```dockerfile
# Stage 2: Runtime
FROM python:3.12-slim
```

Start completely fresh from a clean base image. Stage 1 (builder) is discarded.
Only what we explicitly copy from it survives.

```dockerfile
COPY --from=builder /install /usr/local
```

Copies only the installed Python packages from Stage 1 into the final image.
The result: the final image has NO build tools, NO compiler, NO pip cache —
only what the app actually needs to run.

**Why does image size matter?**
- Smaller images pull faster in CI/CD and Kubernetes
- Smaller attack surface — fewer binaries an attacker can exploit
- Follows the principle of least privilege at the infrastructure level

**Single-stage vs Multi-stage comparison:**

| | Single Stage | Multi-Stage |
|---|---|---|
| Build tools in final image | ✅ Yes (bad) | ❌ No (good) |
| Image size | Larger | Smaller |
| Security surface | Wider | Narrower |
| Complexity | Simple | Slightly more |

---

## 5. psycopg2 vs psycopg2-binary

This is one of the most common sources of Docker build confusion.

| Package | What it does | Needs gcc + libpq-dev? |
|---|---|---|
| `psycopg2` | Compiles from source at install time | ✅ Yes |
| `psycopg2-binary` | Pre-compiled, self-contained binary | ❌ No |

**If your `requirements.txt` has `psycopg2` (no `-binary`):**
You MUST install `gcc` and `libpq-dev` in the builder stage:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*
```
And in the runtime stage, you still need the shared library:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*
```

**If your `requirements.txt` has `psycopg2-binary`:**
Install NOTHING extra. The binary bundles everything it needs.
Adding `gcc` and `libpq-dev` would only waste image size.

**This project uses `psycopg2-binary`** — so no system packages are needed.

---

## 6. Non-Root User

```dockerfile
RUN groupadd --system appgroup && useradd --system --gid appgroup appuser
USER appuser
```

By default, processes inside Docker containers run as `root`. This is dangerous:
if an attacker exploits a vulnerability in your app, they have root access inside
the container — and potentially to the host.

**Always create and switch to a non-root user.**

**`groupadd` vs `addgroup`:**
- `groupadd` / `useradd` — correct syntax for **Debian/Ubuntu** based images
  (`python:3.12-slim` is Debian)
- `addgroup` / `adduser` — correct syntax for **Alpine** based images
  (`python:3.12-alpine`)

Using Alpine syntax on a Debian image will fail silently or produce errors.

**`--system` flag** creates a system account (no home directory, no shell, no
login) — appropriate for service accounts running application processes.

---

## 7. gunicorn

```dockerfile
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "--timeout", "120", "run:app"]
```

Flask has a built-in development server (`flask run`). **Never use it in production.**
It is single-threaded, not designed for concurrent requests, and lacks stability.

**gunicorn** is a production-grade WSGI server:
- Handles multiple requests concurrently via worker processes
- Manages worker lifecycle (restarts crashed workers)
- Integrates with Nginx as a reverse proxy

**Breaking down the command:**

| Argument | Meaning |
|---|---|
| `--bind 0.0.0.0:5000` | Listen on all network interfaces inside the container on port 5000 |
| `--workers 3` | Spawn 3 worker processes. Rule of thumb: `2 * CPU_cores + 1` |
| `--timeout 120` | Kill workers that don't respond within 120 seconds |
| `run:app` | Import the `app` object from `run.py` — `module:variable` format |

**Why is port 5000 hardcoded here?**
CMD in exec form (`["..."]`) does NOT expand environment variables like `$PORT`.
The container's internal port is always fixed. The host-facing port is controlled
in `compose.yml` via `"${PORT:-5000}:5000"` — Docker handles the mapping.

**exec form vs shell form:**
```dockerfile
# Exec form — RECOMMENDED
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "run:app"]

# Shell form — NOT recommended
CMD gunicorn --bind 0.0.0.0:${PORT:-5000} run:app
```
Exec form receives signals (SIGTERM, SIGINT) directly — gunicorn shuts down
gracefully. Shell form wraps in `/bin/sh -c`, signals go to the shell wrapper
and may never reach gunicorn.

---

## 8. Environment Variables Strategy

### The Single .env File Rule

Maintain **one `.env` file** for all environments. Never create `.env.local`,
`.env.docker`, `.env.production` etc. — that leads to drift and confusion.

The only value that changes between bare-metal and Docker is the database host
(`localhost` vs `db`). Docker Compose handles this override automatically.

### How Each Tool Reads .env

| Tool | Reads .env? | Expands `${VAR}`? |
|---|---|---|
| `python-dotenv` (bare-metal) | ✅ Yes | ❌ No — write literal values |
| `docker compose` | ✅ Yes | ✅ Yes — `${VAR}` works |

### The DATABASE_URL Override Pattern

```
.env file:
  DATABASE_URL=postgresql://user:pass@localhost:5432/mydb   ← for bare-metal

compose.yml app service:
  environment:
    DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}
                                                              ↑
                                                  'db' = Docker service name
                                                  resolved as hostname on app-network
```

`compose.yml`'s `environment` block **overrides** the value from `env_file`.
So `.env` always stays with `localhost` — you never need to change it when
switching between bare-metal and Docker Compose.

### Why Not Hardcode Credentials in Code?

Hardcoded credentials:
- Get committed to Git → exposed publicly if repo is public
- Cannot be changed without rebuilding the image
- Differ between environments (dev/staging/prod) — hardcoding forces separate images

Environment variables solve all three problems.

---

## 9. docker compose

`docker compose` orchestrates multiple containers as a single application stack.
Without it, you would need to:
1. Create a network manually
2. Start the PostgreSQL container manually
3. Wait for PostgreSQL to be ready manually
4. Start the Flask container manually with the correct network and env vars

`compose.yml` automates all of this with one command: `docker compose up`.

### Service Order — db First, app Second

```yaml
app:
  depends_on:
    db:
      condition: service_healthy
```

This tells Docker Compose: do not start `app` until `db` passes its healthcheck.
Without this, `app` would start immediately and crash trying to connect to a
PostgreSQL server that hasn't finished initializing yet.

---

## 10. Networking

```yaml
networks:
  app-network:
    driver: bridge
```

By default, Docker Compose creates a default network for all services in the file.
Defining an **explicit named network** is better practice because:
- It is visible in `docker network ls` with a recognizable name
- In multi-compose setups, default networks can conflict
- It makes the intent clear in the file

**How container DNS works:**
Inside `app-network`, each service is reachable by its **service name** as a hostname.
So `db` in the connection URL resolves to the IP address of the `postgres-db` container.
This is why `DATABASE_URL` uses `@db:5432` inside Docker — not `@localhost:5432`.

```
flask-app container:  DATABASE_URL=postgresql://user:pass@db:5432/mydb
                                                            ↑
                                           Docker DNS resolves 'db'
                                           to postgres-db container's IP
```

---

## 11. Healthchecks

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
  interval: 5s
  timeout: 5s
  retries: 5
  start_period: 10s
```

`depends_on` alone only waits for the container to **start** — not for the
process inside it to be **ready**. PostgreSQL takes a few seconds to initialize
its data directory and start accepting connections.

`pg_isready` is a PostgreSQL utility that checks if the server is accepting
connections. The healthcheck runs it every 5 seconds.

| Parameter | Meaning |
|---|---|
| `interval: 5s` | Run the check every 5 seconds |
| `timeout: 5s` | If the check takes longer than 5s, count as failure |
| `retries: 5` | After 5 consecutive failures, mark container as `unhealthy` |
| `start_period: 10s` | Give PostgreSQL 10 seconds to initialize before failures start counting |

`start_period` prevents false `unhealthy` status during first boot when PostgreSQL
is initializing its data directory — a process that can take several seconds.

---

## 12. Volumes

```yaml
volumes:
  postgres_data:
    driver: local
```

```yaml
db:
  volumes:
    - postgres_data:/var/lib/postgresql/data
```

PostgreSQL stores all database files in `/var/lib/postgresql/data` inside the
container. Without a volume, all data is lost when the container is removed.

A **named volume** persists data on the Docker host. Docker manages its location.

| Command | Effect on volume |
|---|---|
| `docker compose down` | Stops containers, removes containers — **volume survives** |
| `docker compose down -v` | Stops containers, removes containers AND volumes — **data is gone** |
| `docker compose up` | Reuses existing volume — data from previous run is restored |

---

## 13. .dockerignore

`.dockerignore` tells Docker which files NOT to copy into the image via `COPY . .`.

```
.env              ← NEVER copy — contains secrets
.git/             ← Version control metadata — not needed at runtime  
__pycache__/      ← Python bytecode cache — rebuilt inside container
*.pyc             ← Compiled Python files — platform-specific, regenerated
venv/             ← Local virtual environment — replaced by /opt/venv in image
.pytest_cache/    ← Test artifacts — not needed at runtime
tests/            ← Test code — not needed at runtime
```

**The most important entry is `.env`** — it contains credentials. If it were
copied into the image, those credentials would be baked into every layer and
visible to anyone who pulls the image.

Docker Compose passes `.env` values at **runtime** via `env_file` — the file
itself never needs to be inside the image.

---

## 14. The SQLAlchemy Pitfall — Duplicate db Instances

This is a subtle but critical Flask + SQLAlchemy mistake that only surfaces
when running under gunicorn (multi-worker) — not during development.

**The wrong pattern:**
```python
# app/models.py
from flask_sqlalchemy import SQLAlchemy
db = SQLAlchemy()          # Instance A

# app/__init__.py
from flask_sqlalchemy import SQLAlchemy
db = SQLAlchemy()          # Instance B  ← second, separate object

def create_app():
    db.init_app(app)       # registers Instance B with the Flask app

# app/routes.py
from .models import db     # imports Instance A — never registered!
items = Item.query.all()   # RuntimeError!
```

**The error:**
```
RuntimeError: The current Flask app is not registered with this 'SQLAlchemy' instance.
Did you forget to call 'init_app', or did you create multiple 'SQLAlchemy' instances?
```

**The correct pattern — one source of truth:**
```python
# app/models.py
from flask_sqlalchemy import SQLAlchemy
db = SQLAlchemy()          # ONE instance, defined here

# app/__init__.py
from app.models import db  # import the SAME instance

def create_app():
    db.init_app(app)       # registers the same db that routes.py uses ✅

# app/routes.py
from .models import db     # same instance — already registered ✅
```

**Rule:** `db = SQLAlchemy()` must appear **exactly once** in the entire codebase.
Everyone else imports it from `models.py`.

---

## 15. Mental Model — Bare-Metal vs Docker Compose

```
┌──────────────────────────────────────────────────────────────────┐
│                        BARE-METAL                                │
│                                                                  │
│  Terminal                                                        │
│  $ python run.py                                                 │
│                                                                  │
│  python-dotenv reads .env                                        │
│  DATABASE_URL = postgresql://user:pass@localhost:5432/db  ✅     │
│  PostgreSQL running on your machine at localhost          ✅     │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                      DOCKER COMPOSE                              │
│                                                                  │
│  Terminal                                                        │
│  $ docker compose up --build                                     │
│                                                                  │
│  compose.yml loads .env via env_file                             │
│  compose.yml overrides DATABASE_URL in app service:              │
│  DATABASE_URL = postgresql://user:pass@db:5432/mydb       ✅     │
│                                              ↑                   │
│                              Docker DNS resolves 'db'            │
│                              to postgres-db container            │
│                                                                  │
│  .env value (@localhost) is IGNORED for the app container ✅     │
└──────────────────────────────────────────────────────────────────┘
```

---

## 16. Quick Reference — Commands

```bash
# ── Build & Run ────────────────────────────────────────────────────────────
docker compose up --build          # Build images and start all services
docker compose up -d --build       # Same but in detached (background) mode
docker compose down                # Stop and remove containers
docker compose down -v             # Stop, remove containers AND volumes (data gone)

# ── Logs ───────────────────────────────────────────────────────────────────
docker compose logs app            # View app logs
docker compose logs db             # View database logs
docker compose logs -f app         # Follow (tail) app logs in real time

# ── Debug ──────────────────────────────────────────────────────────────────
docker compose ps                  # Check container status and health
docker exec -it flask-app bash     # Shell into the running app container
docker exec -it postgres-db bash   # Shell into the running db container
docker network ls                  # List all Docker networks
docker volume ls                   # List all Docker volumes

# ── Image ──────────────────────────────────────────────────────────────────
docker build -t flask-app .        # Build image manually (without compose)
docker image ls                    # List local images
docker image rm flask-app          # Remove image

# ── Rebuild after code changes ─────────────────────────────────────────────
git pull
docker compose down
docker compose up --build
```
