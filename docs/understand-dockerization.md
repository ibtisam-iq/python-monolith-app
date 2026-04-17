# Understand Dockerization — Python Flask + PostgreSQL

This document explains **how to Dockerize any Python Flask application** from scratch.
Everything here is derived from real decisions made in this project — including
what worked, what failed, and why each choice was made.
It also covers every possible Dockerization approach so you can apply this knowledge
to future projects regardless of their architecture.

---

## Table of Contents

1. [The Big Picture — What Dockerization Means](#1-the-big-picture)
2. [Understand the Project Before Writing a Single Line](#2-understand-the-project-first)
3. [2-Tier vs 3-Tier Architecture — Know What You Are Dockerizing](#3-2-tier-vs-3-tier-architecture)
4. [Integrated vs Separated Frontend — How to Identify](#4-integrated-vs-separated-frontend)
5. [The Dockerfile — Line by Line](#5-the-dockerfile)
6. [Multi-Stage Builds — Why and How](#6-multi-stage-builds)
7. [psycopg2 vs psycopg2-binary — A Critical Distinction](#7-psycopg2-vs-psycopg2-binary)
8. [Non-Root User — Security Inside Containers](#8-non-root-user)
9. [gunicorn — Why Not Flask's Built-in Server](#9-gunicorn)
10. [Multiple Dockerfiles — When and Why](#10-multiple-dockerfiles)
11. [Approach A — Single Container (This Project)](#11-approach-a--single-container-this-project)
12. [Approach B — Separate Nginx Frontend Container](#12-approach-b--separate-nginx-frontend-container)
13. [Approach C — Full 3-Tier with React Frontend](#13-approach-c--full-3-tier-with-react-frontend)
14. [Environment Variables Strategy](#14-environment-variables-strategy)
15. [docker compose — Orchestrating Multiple Containers](#15-docker-compose)
16. [Networking — How Containers Talk to Each Other](#16-networking)
17. [Healthchecks — Why depends_on Alone is Not Enough](#17-healthchecks)
18. [Volumes — Persisting Database Data](#18-volumes)
19. [.dockerignore — What NOT to Copy](#19-dockerignore)
20. [The SQLAlchemy Pitfall — Duplicate db Instances](#20-the-sqlalchemy-pitfall)
21. [Mental Model — Bare-Metal vs Docker Compose](#21-mental-model)
22. [Quick Reference — Commands](#22-quick-reference)

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

| Question | What to look for |
|---|---|
| What Python version? | `runtime.txt`, `pyproject.toml`, `requirements.txt`, `Pipfile` |
| What does the app need at runtime? | `requirements.txt` — all libraries listed |
| Does it need a database? | Look for SQLAlchemy, psycopg2, pymysql, pymongo in requirements |
| Does it need build tools to compile? | `psycopg2` (no -binary) needs gcc; `psycopg2-binary` does not |
| How is it started? | Check `run.py`, `manage.py`, `Procfile`, `README` |
| What port does it listen on? | Look for `app.run(port=...)` or `PORT` env var |
| What config does it need? | Look for `os.environ.get(...)` calls in `config.py` |
| Is there a frontend framework? | React/Vue/Angular → separate container; Jinja2 templates → same container |
| Is it 2-tier or 3-tier? | See Section 3 below |

**This project's answers:**

| Question | Answer |
|---|---|
| Python version | 3.12 |
| Runtime dependencies | Flask, SQLAlchemy, gunicorn, psycopg2-binary |
| Database | PostgreSQL |
| Build tools needed | None — psycopg2-binary is pre-compiled |
| Start command | `gunicorn run:app` in production |
| Port | 5000 (configurable via `PORT` env var) |
| Config needed | `DATABASE_URL`, `PORT` |
| Frontend type | Jinja2 templates (integrated — same container as Flask) |
| Architecture | 2-tier |

---

## 3. 2-Tier vs 3-Tier Architecture

Understanding the architecture of the project determines HOW MANY containers
you need and HOW MANY Dockerfiles you write.

### 2-Tier Architecture

```
┌───────────────────────────────────────┐
│         Client (Browser)              │
└──────────────────┬────────────────────┘
                   │ HTTP request
┌──────────────────▼────────────────────┐
│    Tier 1: Application (Flask)        │
│    - Business logic                   │
│    - Renders HTML via Jinja2          │
│    - Serves static files (CSS/JS)     │
└──────────────────┬────────────────────┘
                   │ SQL queries
┌──────────────────▼────────────────────┐
│    Tier 2: Database (PostgreSQL)      │
└───────────────────────────────────────┘
```

- Flask handles BOTH the business logic AND the presentation (HTML rendering)
- No separate frontend framework
- **This project is 2-tier**
- Dockerization: **2 containers** — Flask app + PostgreSQL
- Dockerfiles needed: **1** (for Flask; PostgreSQL uses the official image)

### 3-Tier Architecture

```
┌───────────────────────────────────────┐
│         Client (Browser)              │
└──────────────────┬────────────────────┘
                   │ HTTP
┌──────────────────▼────────────────────┐
│  Tier 1: Presentation (React/Vue/     │
│          Angular or Nginx)            │
└──────────────────┬────────────────────┘
                   │ REST API / JSON
┌──────────────────▼────────────────────┐
│  Tier 2: Application (Flask API)      │
│  - Business logic only                │
│  - Returns JSON, not HTML             │
└──────────────────┬────────────────────┘
                   │ SQL queries
┌──────────────────▼────────────────────┐
│  Tier 3: Database (PostgreSQL)        │
└───────────────────────────────────────┘
```

- Flask serves ONLY API endpoints (returns JSON, no HTML templates)
- Frontend is a completely separate project (React, Vue, Angular)
- Dockerization: **3 containers** — Frontend + Flask API + PostgreSQL
- Dockerfiles needed: **2** (Frontend + Flask; PostgreSQL uses official image)

### Summary Table

| | 2-Tier | 3-Tier |
|---|---|---|
| Frontend | Jinja2 templates inside Flask | React/Vue/Angular — separate project |
| Flask returns | HTML pages | JSON responses |
| Containers | 2 | 3 |
| Dockerfiles | 1 | 2 |
| Complexity | Simpler | More modular |
| Scalability | Limited | Frontend/backend scale independently |

---

## 4. Integrated vs Separated Frontend — How to Identify

When you pick up someone else's Python project, use these signals to determine
whether the frontend is integrated or separate.

### Signs of Integrated Frontend (2-Tier)

```
project/
├── app/
│   ├── templates/        ← HTML files rendered by Flask (Jinja2)
│   │   ├── index.html
│   │   └── layout.html
│   ├── static/           ← CSS/JS served directly by Flask
│   │   └── css/style.css
│   ├── routes.py         ← returns render_template(...), not jsonify(...)
│   └── models.py
├── config.py
└── run.py
```

**Key indicator in `routes.py`:**
```python
# Integrated — Flask renders HTML
return render_template('index.html', items=items)  # ← 2-tier
```

### Signs of Separated Frontend (3-Tier)

```
project/
├── backend/              ← Flask API only
│   ├── app/
│   │   └── routes.py     ← returns jsonify(...), no templates
│   └── run.py
└── frontend/             ← completely separate project
    ├── src/
    │   ├── components/
    │   └── App.jsx
    ├── public/
    └── package.json      ← Node.js frontend build system
```

**Key indicator in `routes.py`:**
```python
# Separated — Flask returns JSON only
return jsonify({'items': items})  # ← 3-tier
```

**Other signals:**
- `package.json` in the project → frontend build system (Node/React/Vue)
- `.jsx`, `.tsx`, `.vue` files → separate frontend framework
- No `templates/` folder in backend → Flask is API-only
- Routes like `/api/users`, `/api/items` → REST API pattern

---

## 5. The Dockerfile — Line by Line

```dockerfile
# Stage 1: Builder
FROM python:3.12-slim AS builder
```

`python:3.12-slim` is a Debian-based image with Python pre-installed but without
extra tools. `AS builder` names this stage — we reference it later in Stage 2.

**Base image choices:**

| Image | Size | OS | Use when |
|---|---|---|---|
| `python:3.12` | ~1GB | Debian | Full toolchain needed |
| `python:3.12-slim` | ~130MB | Debian | Most production apps |
| `python:3.12-alpine` | ~50MB | Alpine | Absolute minimum size |

> **Warning:** Alpine uses `musl libc` instead of `glibc`. Some Python packages
> (especially those with C extensions) can behave unexpectedly on Alpine.
> Prefer `slim` for reliability.

```dockerfile
WORKDIR /app
```

Sets the working directory inside the container. All subsequent `COPY`, `RUN`,
`CMD` instructions operate relative to `/app`. Creates the directory if it doesn't exist.

```dockerfile
COPY requirements.txt .
RUN pip install --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt
```

**Why copy `requirements.txt` before the rest of the code?**
Docker builds in layers. If `requirements.txt` hasn't changed, Docker reuses the
cached layer and skips reinstalling dependencies — even if your application code
changed. This makes rebuilds significantly faster.

`--no-cache-dir` tells pip not to cache downloaded packages — reduces image size.

```dockerfile
COPY --chown=appuser:appgroup . .
```

Copies all remaining application files AND sets ownership to `appuser:appgroup`
in a single layer.

**Why `--chown` at `COPY` time instead of a separate `RUN chown` layer?**

The naive approach uses two steps:
```dockerfile
COPY . .                              # Layer 1 — files copied, owned by root
RUN chown -R appuser:appgroup /app    # Layer 2 — ownership changed
```
This doubles the layer size because Docker stores BOTH the original root-owned
copy AND the re-owned copy in separate layers. The image ends up carrying the
data twice.

The correct approach:
```dockerfile
COPY --chown=appuser:appgroup . .     # Single layer — copied AND owned correctly
```
One layer, correct ownership from the start, no size penalty.

> **Important:** `appuser` must be created with `RUN groupadd / useradd` BEFORE
> this `COPY` instruction. You cannot `--chown` to a user that doesn't exist yet.

---

## 6. Multi-Stage Builds

A multi-stage build uses multiple `FROM` instructions in one Dockerfile.
Each `FROM` starts a new stage. Only what you explicitly `COPY --from=<stage>`
carries forward. Everything else is discarded.

```dockerfile
# ── Stage 1: Builder ─────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --upgrade pip \
    && pip install --prefix=/install --no-cache-dir -r requirements.txt

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /install /usr/local   # ← only packages, no build tools
COPY . .
```

**`--prefix=/install`** installs packages into `/install` instead of the
system Python. This isolates them so Stage 2 can copy them cleanly.

**Alternative — virtual environment approach (used in this project):**
```dockerfile
# Stage 1
FROM python:3.12-slim AS builder
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Stage 2
FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv   # ← copy entire venv
ENV PATH="/opt/venv/bin:$PATH"
COPY --chown=appuser:appgroup . .
```

Both approaches achieve the same goal. The venv approach is more explicit and
isolated; the `--prefix` approach is slightly more concise.

**Why does image size matter?**
- Smaller images pull faster in CI/CD and Kubernetes
- Smaller attack surface — fewer binaries an attacker can exploit
- Follows the principle of least privilege at the infrastructure level

| | Single Stage | Multi-Stage |
|---|---|---|
| Build tools in final image | ✅ Yes (bad) | ❌ No (good) |
| Image size | Larger | Smaller |
| Security surface | Wider | Narrower |
| Complexity | Simple | Slightly more |

---

## 7. psycopg2 vs psycopg2-binary

This is one of the most common sources of Docker build confusion.

| Package | What it does | Needs gcc + libpq-dev? |
|---|---|---|
| `psycopg2` | Compiles from source at install time | ✅ Yes |
| `psycopg2-binary` | Pre-compiled, self-contained binary | ❌ No |

**If your `requirements.txt` has `psycopg2` (no `-binary`):**
```dockerfile
# Builder stage — needs compiler and PostgreSQL headers
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Runtime stage — needs only the shared library, not the compiler
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*
```

**If your `requirements.txt` has `psycopg2-binary`:**
Install NOTHING extra. The binary bundles everything it needs.

> **This project uses `psycopg2-binary`** — no system packages needed.

---

## 8. Non-Root User — Security Inside Containers

```dockerfile
RUN groupadd --gid 1001 appgroup \
    && useradd --uid 1001 --gid appgroup --no-create-home appuser
```

By default, processes inside Docker containers run as `root`. This is dangerous:
if an attacker exploits a vulnerability in your app, they have root access inside
the container — and potentially to the host.

**Always create and switch to a non-root user.**

**`groupadd` vs `addgroup` — which to use:**

| Command | OS | Base image |
|---|---|---|
| `groupadd` / `useradd` | Debian/Ubuntu | `python:3.12-slim`, `python:3.12` |
| `addgroup` / `adduser` | Alpine | `python:3.12-alpine`, `nginx:alpine` |

Using Alpine syntax on a Debian image (or vice versa) will fail.

**Explicit UID/GID (`--uid 1001 --gid 1001`) vs `--system`:**

| Flag | UID assigned | Use when |
|---|---|---|
| `--system` | Auto-assigned (low number, e.g. 999) | Simple cases, UID doesn't matter |
| `--uid 1001 --gid 1001` | Explicitly fixed | Kubernetes (Pod Security, volume ownership), rootless Docker |

This project uses explicit `1001` so the UID is predictable and stable across
environments. Kubernetes volume mounts and `securityContext.runAsUser` depend on
a known, fixed UID.

**`--no-create-home`** skips creating a home directory — this is a service
account, not an interactive user. Keeps the image minimal.

### Ownership — `COPY --chown` vs `RUN chown`

```dockerfile
# ❌ Wrong — doubles the layer size
COPY . .
RUN chown -R appuser:appgroup /app

# ✅ Correct — single layer, ownership set at copy time
COPY --chown=appuser:appgroup . .
```

See Section 5 for the full explanation of why `--chown` at `COPY` time is always
preferred over a separate `RUN chown` layer.

```dockerfile
# Always switch to non-root user as the last step before CMD/ENTRYPOINT
USER appuser
```

Everything after `USER appuser` — including `EXPOSE`, `HEALTHCHECK`, `CMD` —
runs as the non-root user.

---

## 9. gunicorn — Why Not Flask's Built-in Server

Flask has a built-in development server (`flask run`). **Never use it in production.**
It is single-threaded, not designed for concurrent requests, and lacks stability.

**gunicorn** is a production-grade WSGI server:
- Handles multiple requests concurrently via worker processes
- Manages worker lifecycle (restarts crashed workers)
- Integrates with Nginx as a reverse proxy

### exec form vs shell form — A Critical Distinction

```dockerfile
# Exec form — signals go directly to gunicorn — port is HARDCODED
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "--timeout", "120", "run:app"]

# Shell form — required when environment variable expansion is needed
CMD ["sh", "-c", "gunicorn --bind 0.0.0.0:${PORT:-5000} --workers 3 --timeout 120 run:app"]
```

**Why exec form does NOT support `$PORT`:**
In exec form, Docker passes the array directly to the kernel with `execve()` —
no shell is involved, so `${PORT}` is passed as a literal string, not expanded.

**Why this project uses shell form:**
`PORT` is configurable via the `.env` file and the `compose.yml` environment block.
If `PORT=8080` is set, the container must bind on `8080`. Using `sh -c` invokes
a shell that expands `${PORT:-5000}` before passing it to gunicorn.

The `:-5000` syntax is a shell default — if `PORT` is unset or empty, `5000` is used.

**Signal handling note:**
Shell form wraps the process in `sh -c`, which means `SIGTERM` (sent by
`docker stop`) goes to `sh`, not directly to gunicorn. Gunicorn handles graceful
shutdown correctly in this case because `sh` forwards the signal — but if you
need zero-latency signal forwarding, use `exec gunicorn ...` inside the shell:

```dockerfile
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT:-5000} --workers 3 --timeout 120 run:app"]
```

`exec` replaces the `sh` process with gunicorn — PID 1 becomes gunicorn directly.

**gunicorn arguments explained:**

| Argument | Meaning |
|---|---|
| `--bind 0.0.0.0:${PORT:-5000}` | Listen on all interfaces, port from env (default 5000) |
| `--workers 3` | Spawn 3 worker processes. Rule of thumb: `2 * CPU_cores + 1` |
| `--timeout 120` | Kill workers that don't respond within 120 seconds |
| `run:app` | Import the `app` object from `run.py` — `module:variable` format |

---

## 10. Multiple Dockerfiles — When and Why

A project has ONE Dockerfile per **independently built service**.
The PostgreSQL database always uses the official `postgres` image — no
Dockerfile needed for it.

| Architecture | Dockerfiles needed | File names |
|---|---|---|
| 2-tier (Flask + PostgreSQL) | 1 | `Dockerfile` |
| 2-tier + Nginx frontend | 2 | `Dockerfile`, `Dockerfile.frontend` |
| 3-tier (React + Flask + PostgreSQL) | 2 | `Dockerfile` (Flask), `Dockerfile.frontend` (React/Nginx) |

**How compose.yml references multiple Dockerfiles:**
```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile           # Flask backend

  frontend:
    build:
      context: .
      dockerfile: Dockerfile.frontend  # Nginx or React build

  db:
    image: postgres:16-alpine          # No Dockerfile — uses official image
```

---

## 11. Approach A — Single Container (This Project)

This is the correct approach for **2-tier apps** where Flask serves both
the business logic and the HTML templates (Jinja2).

```
Containers:  flask-app  ←→  postgres-db
Dockerfiles: 1 (Dockerfile)
```

**`Dockerfile`** (see full file in project root)

**`compose.yml`:**
```yaml
services:
  db:
    image: postgres:16-alpine
    container_name: postgres-db
    ...

  app:
    build: .
    container_name: flask-app
    ports:
      - "${PORT:-5000}:${PORT:-5000}"
    depends_on:
      db:
        condition: service_healthy
```

**When to use:**
- Flask app uses Jinja2 templates
- No separate JavaScript frontend framework
- Static files (CSS/JS) are served directly by Flask
- Project is 2-tier

---

## 12. Approach B — Separate Nginx Frontend Container

Use this when you want to serve static files (HTML/CSS/JS) from a dedicated
Nginx container, while Flask handles only backend logic.
This makes sense even for 2-tier apps when you want a proper web server in front.

```
Containers:  nginx-frontend  →  flask-app  →  postgres-db
Dockerfiles: 2 (Dockerfile + Dockerfile.frontend)
```

**`Dockerfile.frontend`:**
```dockerfile
# Serve static files and proxy API requests to Flask
FROM nginx:alpine

# Copy static HTML/CSS into Nginx's web root
COPY ./app/static /usr/share/nginx/html/static
COPY ./app/templates /usr/share/nginx/html

# Copy custom Nginx config to proxy /api requests to Flask
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
```

**`nginx.conf`:**
```nginx
server {
    listen 80;

    # Serve static files directly
    location /static/ {
        root /usr/share/nginx/html;
    }

    # Proxy all other requests to Flask
    location / {
        proxy_pass http://app:5000;   # 'app' = Flask service name on Docker network
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

**`compose.yml`:**
```yaml
services:
  db:
    image: postgres:16-alpine
    container_name: postgres-db
    ...

  app:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: flask-app
    # No ports exposed to host — Nginx is the only entry point
    depends_on:
      db:
        condition: service_healthy

  frontend:
    build:
      context: .
      dockerfile: Dockerfile.frontend
    container_name: nginx-frontend
    ports:
      - "80:80"       # Only Nginx is publicly accessible
    depends_on:
      - app

networks:
  app-network:
    driver: bridge
```

**When to use:**
- You want Nginx handling SSL termination, compression, and static file caching
- You want Flask to be completely private (not exposed to the internet directly)
- You are moving towards a production-grade deployment

---

## 13. Approach C — Full 3-Tier with React Frontend

Use this when the frontend is a completely separate JavaScript project
(React, Vue.js, Angular) and Flask serves only a REST API.

```
Containers:  react-app (Nginx)  →  flask-api  →  postgres-db
Dockerfiles: 2 (Dockerfile for Flask, Dockerfile.frontend for React build)
```

**Project structure for 3-tier:**
```
project/
├── backend/
│   ├── app/
│   │   ├── __init__.py
│   │   ├── models.py
│   │   └── routes.py        ← returns jsonify(), no render_template()
│   ├── config.py
│   ├── run.py
│   └── Dockerfile
├── frontend/
│   ├── src/
│   │   ├── components/
│   │   └── App.jsx
│   ├── public/index.html
│   ├── package.json
│   └── Dockerfile.frontend
└── compose.yml
```

**`Dockerfile.frontend` (React multi-stage build):**
```dockerfile
# Stage 1: Build the React app
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json .
RUN npm ci                      # Install dependencies
COPY . .
RUN npm run build               # Produces /app/dist or /app/build

# Stage 2: Serve the built files with Nginx
FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

**Flask `routes.py` in 3-tier — returns JSON only:**
```python
from flask import jsonify

@app.route('/api/items')
def get_items():
    items = Item.query.all()
    return jsonify([{'id': i.id, 'name': i.name} for i in items])  # JSON, not HTML
```

**`compose.yml`:**
```yaml
services:
  db:
    image: postgres:16-alpine
    container_name: postgres-db
    ...

  app:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: flask-api
    # Not exposed to host — only frontend talks to it
    depends_on:
      db:
        condition: service_healthy

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile.frontend
    container_name: react-app
    ports:
      - "80:80"    # Only frontend is publicly exposed
    depends_on:
      - app

networks:
  app-network:
    driver: bridge
```

**When to use:**
- Project has a React/Vue/Angular frontend in a separate folder
- Flask returns only JSON — no `render_template()` anywhere
- Frontend and backend need to scale independently
- Modern microservices or SPA architecture

---

## 14. Environment Variables Strategy

### The Single .env File Rule

Maintain **one `.env` file** for all environments. Never create `.env.local`,
`.env.docker`, `.env.production` etc. — that leads to drift and confusion.

The only value that changes between bare-metal and Docker is the database host
(`localhost` vs `db`). Docker Compose handles this override automatically.

### How Each Tool Reads .env

| Tool | Reads .env? | Expands `${VAR}`? | Write values as |
|---|---|---|---|
| `python-dotenv` (bare-metal) | ✅ Yes | ❌ No | Literal values only |
| `docker compose` | ✅ Yes | ✅ Yes | Literal OR `${VAR}` both work |

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

### env_file vs environment — The Difference

```yaml
app:
  env_file: .env          # Loads ALL variables from .env into the container
  environment:            # Overrides specific variables — takes priority over env_file
    DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}
```

- `env_file` = bulk loader — loads everything
- `environment` = surgical override — changes only specific values
- When both are present, `environment` wins for any key that appears in both

### Why Not Hardcode Credentials in Code?

- Hardcoded credentials get committed to Git → exposed publicly if repo is public
- Cannot be changed without rebuilding the image
- Differ between environments (dev/staging/prod) — hardcoding forces separate images

---

## 15. docker compose — Orchestrating Multiple Containers

`docker compose` orchestrates multiple containers as a single application stack.
Without it, you would need to:
1. Create a network manually: `docker network create app-network`
2. Start PostgreSQL manually: `docker run --network app-network postgres:16-alpine`
3. Wait for PostgreSQL to be ready manually
4. Start Flask manually with all the correct env vars and network flags

`compose.yml` automates all of this with one command: `docker compose up`.

### The `name:` Field — Compose Project Name

```yaml
name: python-monolith-app
```

Every Compose stack has a **project name**. Docker uses it to prefix all
resources it creates — containers, networks, and volumes:

```
Without name:   directory name is used as prefix
  e.g. on machine A:  myproject-app-1, myproject-app-network
  e.g. on machine B:  python-monolith-app-app-1  (different directory name → different prefix)

With name: python-monolith-app:
  Always:       python-monolith-app-app-1, python-monolith-app-app-network
```

Setting `name:` explicitly guarantees consistent resource naming regardless
of the directory the project is cloned into. This matters in CI/CD pipelines
where workspace directories are auto-generated and unpredictable.

### The `image:` Field on a Build Service

```yaml
app:
  build:
    context: .
    dockerfile: Dockerfile
  image: python-monolith-app     # ← explicit image name
```

When a service has both `build:` and `image:`, Docker Compose:
1. Builds the image from the Dockerfile
2. Tags the result as `python-monolith-app:latest`

Without `image:`, the built image gets an auto-generated name like
`python-monolith-app-app` — not suitable for pushing to a registry.
With `image:`, you can push it directly:

```bash
docker compose build
docker push python-monolith-app:latest    # works cleanly with an explicit name
```

### Service Order — db First, app Second

```yaml
app:
  depends_on:
    db:
      condition: service_healthy
```

`depends_on` without `condition` only waits for the container to **start**,
not for PostgreSQL to be **ready to accept connections**. Always use
`condition: service_healthy` with a proper healthcheck.

### container_name — Why Explicit Names Matter

```yaml
app:
  container_name: flask-app
db:
  container_name: postgres-db
```

Without `container_name`, Docker Compose generates names like
`python-monolith-app-app-1`. With explicit names:
```bash
docker logs flask-app        # clean, memorable
docker exec -it flask-app bash
docker exec -it postgres-db psql -U myuser -d mydb
```

---

## 16. Networking

```yaml
networks:
  app-network:
    driver: bridge
```

By default, Docker Compose creates a default network for all services.
Defining an **explicit named network** is better practice:
- Visible in `docker network ls` with a recognizable name
- In multi-compose setups, default networks can conflict with each other
- Makes intent clear in the file

**How container DNS works:**
Inside `app-network`, each service is reachable by its **service name** as a hostname.

```
Service name in compose.yml → hostname inside Docker network

  db    → resolves to postgres-db container's IP
  app   → resolves to flask-app container's IP

flask-app:  DATABASE_URL=postgresql://user:pass@db:5432/mydb
                                                  ↑
                                Docker DNS resolves 'db'
                                to postgres-db container's IP
```

This is why `DATABASE_URL` uses `@db:5432` inside Docker — not `@localhost:5432`.
`localhost` inside a container refers to the container itself, not other containers.

---

## 17. Healthchecks — Why depends_on Alone is Not Enough

Healthchecks operate at two levels in this project: the **database level** and
the **application level**. Both are necessary for a production-grade setup.

### Level 1 — Database Healthcheck (PostgreSQL)

```yaml
db:
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
    interval: 5s
    timeout: 5s
    retries: 5
    start_period: 10s
```

`pg_isready` is a PostgreSQL utility that checks if the server is accepting
connections. The healthcheck runs it every 5 seconds.

| Parameter | Meaning |
|---|---|
| `interval: 5s` | Run the check every 5 seconds |
| `timeout: 5s` | If the check takes longer than 5s, count as failure |
| `retries: 5` | After 5 consecutive failures, mark container as `unhealthy` |
| `start_period: 10s` | Give PostgreSQL 10 seconds to initialize before failures start counting |

`start_period` prevents false `unhealthy` status on first boot — PostgreSQL
takes several seconds to initialize its data directory before it can accept connections.

### Level 2 — Application Healthcheck (Flask)

The application healthcheck works across three connected layers:

**Layer 1 — The `/health` route in `app/routes.py`:**
```python
@main.route('/health')
def health():
    try:
        db.session.execute(db.text('SELECT 1'))
        return jsonify(status='healthy', database='reachable'), 200
    except Exception as e:
        return jsonify(status='unhealthy', error=str(e)), 503
```

This endpoint does a real database probe — not just a process check.
It executes `SELECT 1` against PostgreSQL. If the query succeeds, the app
is healthy. If it fails (network issue, DB crash, connection pool exhausted),
it returns `503 Service Unavailable` with the error detail.

**Why probe the database from the health endpoint?**
A Flask process can be running (the Python interpreter is alive) but completely
non-functional if the database connection is broken. A process-only check would
report `healthy` while every user request fails. The DB probe catches this.

**Layer 2 — `HEALTHCHECK` in the Dockerfile:**
```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT:-5000}/health')" \
    || exit 1
```

| Parameter | Meaning |
|---|---|
| `--interval=30s` | Check every 30 seconds |
| `--timeout=10s` | Fail if no response within 10 seconds |
| `--start-period=30s` | Wait 30s after container starts before counting failures — gives Flask time to connect to PostgreSQL |
| `--retries=3` | Mark as `unhealthy` after 3 consecutive failures |

`python -c "import urllib.request; ..."` uses the standard library — no curl,
no wget needed. This works in `python:3.12-slim` without installing anything extra.

`${PORT:-5000}` expands inside the Dockerfile `HEALTHCHECK` because Docker
evaluates it through the shell at runtime.

**Layer 3 — `healthcheck` in `compose.yml` on the `app` service:**
```yaml
app:
  healthcheck:
    test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:${PORT:-5000}/health')\""]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 30s
```

The `compose.yml` healthcheck **overrides** the Dockerfile `HEALTHCHECK` for
local development. Both call the same `/health` endpoint. The Compose version
is useful because it shows real-time health status in `docker compose ps`:

```bash
$ docker compose ps
NAME          IMAGE                  STATUS
flask-app     python-monolith-app    Up (healthy)
postgres-db   postgres:16-alpine     Up (healthy)
```

**The full dependency chain:**

```
postgres-db   → pg_isready passes     → status: healthy
     ↓
flask-app     → waits (condition: service_healthy)
     ↓         → starts gunicorn
               → connects to PostgreSQL
               → /health returns 200  → status: healthy
```

**Kubernetes note:**
In Kubernetes, the Dockerfile `HEALTHCHECK` is ignored. Kubernetes uses its own
`livenessProbe` and `readinessProbe` — both should point to `/health`:

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 30
  periodSeconds: 30

readinessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 10
  periodSeconds: 10
```

The `/health` endpoint added to `routes.py` serves Docker, Docker Compose,
and Kubernetes — one endpoint, three consumers.

---

## 18. Volumes — Persisting Database Data

```yaml
volumes:
  postgres_data:
    driver: local

services:
  db:
    volumes:
      - postgres_data:/var/lib/postgresql/data
```

PostgreSQL stores all database files in `/var/lib/postgresql/data`.
Without a volume, all data is lost when the container is removed.

| Command | Effect on volume |
|---|---|
| `docker compose down` | Stops + removes containers — **volume survives** |
| `docker compose down -v` | Stops + removes containers AND volumes — **data is gone** |
| `docker compose up` | Reuses existing volume — data from previous run is restored |
| `docker volume ls` | Lists all volumes |
| `docker volume rm <name>` | Manually removes a volume |

---

## 19. .dockerignore — What NOT to Copy

`.dockerignore` tells Docker which files NOT to include in the build context
when `COPY . .` is executed.

```
.env              ← NEVER copy — contains secrets, baked into image layers
.git/             ← Version control metadata — not needed at runtime
__pycache__/      ← Python bytecode cache — rebuilt inside container
*.pyc             ← Compiled Python files — platform-specific
venv/             ← Local virtual environment — replaced by /opt/venv in image
.pytest_cache/    ← Test artifacts — not needed at runtime
tests/            ← Test code — not needed in production image
*.md              ← Documentation — not needed at runtime
docs/             ← Documentation folder — not needed at runtime
```

**The most critical entry is `.env`** — if it were copied into the image,
credentials would be baked into every layer and visible to anyone who pulls
the image with `docker history` or `docker inspect`.

Docker Compose passes `.env` values at **runtime** via `env_file` — the
file never needs to be inside the image.

---

## 20. The SQLAlchemy Pitfall — Duplicate db Instances

This bug is invisible during development (`python run.py`) but crashes
immediately under gunicorn's multi-worker process model.

**The wrong pattern — two separate db objects:**
```python
# app/models.py
from flask_sqlalchemy import SQLAlchemy
db = SQLAlchemy()          # Instance A

# app/__init__.py
from flask_sqlalchemy import SQLAlchemy
db = SQLAlchemy()          # Instance B  ← second, separate object!

def create_app():
    db.init_app(app)       # registers Instance B with the app

# app/routes.py
from .models import db     # imports Instance A — never registered with app!
items = Item.query.all()   # RuntimeError!
```

**The error you will see:**
```
RuntimeError: The current Flask app is not registered with this 'SQLAlchemy' instance.
Did you forget to call 'init_app', or did you create multiple 'SQLAlchemy' instances?
```

**The correct pattern — single source of truth:**
```python
# app/models.py
from flask_sqlalchemy import SQLAlchemy
db = SQLAlchemy()          # ONE instance — defined here, imported everywhere else

# app/__init__.py
from app.models import db  # import the SAME instance — do NOT create a new one

def create_app():
    db.init_app(app)       # now routes.py and __init__.py share the same db ✅

# app/routes.py
from .models import db     # same instance — already registered ✅
```

**Rule:** `db = SQLAlchemy()` must appear **exactly once** in the codebase.

---

## 21. Mental Model — Bare-Metal vs Docker Compose

```
┌──────────────────────────────────────────────────────────────────┐
│                        BARE-METAL                                │
│                                                                  │
│  $ python run.py                                                 │
│                                                                  │
│  python-dotenv reads .env directly                               │
│  DATABASE_URL = postgresql://user:pass@localhost:5432/db  ✅     │
│  PostgreSQL must be running on your machine at localhost          │
│  python-dotenv does NOT expand ${...} — literal values only      │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                      DOCKER COMPOSE                              │
│                                                                  │
│  $ docker compose up --build                                     │
│                                                                  │
│  Step 1: compose.yml loads .env via env_file                     │
│  Step 2: compose.yml OVERRIDES DATABASE_URL in app service:      │
│          DATABASE_URL = postgresql://user:pass@db:5432/mydb ✅   │
│                                              ↑                   │
│                          Docker DNS resolves 'db' to             │
│                          postgres-db container's IP              │
│                                                                  │
│  Result: .env value (@localhost) is IGNORED for app container    │
│  compose.yml DOES expand ${...} — both literal and ${VAR} work   │
└──────────────────────────────────────────────────────────────────┘
```

**The key insight:**
You never need to change `.env` when switching between bare-metal and Docker.
Docker Compose handles the `localhost` → `db` substitution automatically
through the `environment` override block in `compose.yml`.

---

## 22. Quick Reference — Commands

```bash
# ── Setup ──────────────────────────────────────────────────────────────────
cp .env.example .env           # Create your .env from the template

# ── Build & Run ────────────────────────────────────────────────────────────
docker compose up --build          # Build images and start all services
docker compose up -d --build       # Same but in detached (background) mode
docker compose down                # Stop and remove containers
docker compose down -v             # Stop, remove containers AND volumes

# ── Logs ───────────────────────────────────────────────────────────────────
docker compose logs app            # View app logs
docker compose logs db             # View database logs
docker compose logs -f app         # Follow (tail) app logs in real time

# ── Health ─────────────────────────────────────────────────────────────────
docker compose ps                  # Check container status and health
curl http://localhost:5000/health  # Test the health endpoint manually

# ── Debug ──────────────────────────────────────────────────────────────────
docker exec -it flask-app bash     # Shell into the running app container
docker exec -it postgres-db bash   # Shell into the running db container
docker exec -it postgres-db psql -U <user> -d <db>  # Connect to PostgreSQL
docker network ls                  # List all Docker networks
docker network inspect app-network # Inspect the app network
docker volume ls                   # List all Docker volumes

# ── Image ──────────────────────────────────────────────────────────────────
docker build -t python-monolith-app .   # Build image manually (without compose)
docker image ls                         # List local images
docker image rm python-monolith-app     # Remove image
docker history python-monolith-app      # Inspect image layers

# ── Rebuild after code changes ─────────────────────────────────────────────
git pull
docker compose down
docker compose up --build
```
