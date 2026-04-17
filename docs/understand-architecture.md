# Understand Architecture — Python Flask + PostgreSQL

This document explains **every file in this project** from a DevOps engineer's perspective.
The goal is simple: when you pick up any Flask project, you should be able to open
a file, understand exactly what it does, and immediately know what decisions it
forces on your Dockerfile, `compose.yml`, and CI/CD pipeline.

This is not a beginner Python tutorial. It is a **mental model** for reading
python projects as infrastructure — understanding the dependency chain, the
required environment, and the correct way to run the application.

---

## Table of Contents

1. [Full Project Structure](#1-full-project-structure)
2. [The Request Lifecycle — How Everything Connects](#2-the-request-lifecycle)
3. [run.py — The Entry Point](#3-runpy--the-entry-point)
4. [config.py — Environment Configuration](#4-configpy--environment-configuration)
5. [app/__init__.py — Application Factory](#5-appinit-py--application-factory)
6. [app/models.py — Database Schema](#6-appmodelspy--database-schema)
7. [app/routes.py — URL Routing and Business Logic](#7-approutespy--url-routing-and-business-logic)
8. [app/templates/ — Jinja2 HTML Templates](#8-apptemplates--jinja2-html-templates)
9. [app/static/ — CSS, JavaScript, Images](#9-appstatic--css-javascript-images)
10. [requirements.txt — Python Dependencies](#10-requirementstxt--python-dependencies)
11. [.env and .env.example — Runtime Secrets](#11-env-and-envexample--runtime-secrets)
12. [.gitignore — What Git Must Never Track](#12-gitignore--what-git-must-never-track)
13. [.dockerignore — What Docker Must Never Copy](#13-dockerignore--what-docker-must-never-copy)
14. [tests/ — Automated Test Suite](#14-tests--automated-test-suite)
15. [Dependency Chain — Who Imports Who](#15-dependency-chain--who-imports-who)
16. [File Deletion Guide — What Is Optional](#16-file-deletion-guide--what-is-optional)
17. [DevOps Decision Map — File → Infrastructure Impact](#17-devops-decision-map--file--infrastructure-impact)
18. [Bare-Metal Setup Walkthrough](#18-bare-metal-setup-walkthrough)

---

## 1. Full Project Structure

```
python-monolith-app/
│
├── app/                          ← Python package — the application itself
│   ├── __init__.py               ← Application factory — creates the Flask app
│   ├── models.py                 ← Database table definitions (SQLAlchemy)
│   ├── routes.py                 ← URL endpoints and business logic
│   ├── static/                   ← Files served directly to the browser
│   │   └── css/
│   │       └── style.css         ← Stylesheet for all HTML pages
│   └── templates/                ← Jinja2 HTML templates rendered by Flask
│       ├── layout.html           ← Base template — all others extend this
│       ├── index.html            ← Homepage — lists all items
│       ├── create.html           ← Form to create a new item
│       ├── view.html             ← Detail view of a single item
│       ├── edit.html             ← Form to edit an existing item
│       ├── delete.html           ← Confirmation page before deleting
│       └── update.html           ← Post-update confirmation (if used)
│
├── config.py                     ← Reads DATABASE_URL from environment
├── run.py                        ← Entry point — starts the Flask dev server
├── requirements.txt              ← All Python dependencies
│
├── .env                          ← Your actual secrets (NEVER commit to Git)
├── .env.example                  ← Template showing required variable names
├── .gitignore                    ← Files Git should never track
├── .dockerignore                 ← Files Docker should never copy into images
│
├── tests/                        ← Automated tests
│   ├── __init__.py               ← Makes tests/ a Python package
│   └── test_app.py               ← Test cases for routes and models
│
├── docs/                         ← Documentation
│   ├── Understand-Architecture.md  ← This file
│   └── Understand-Dockerization.md
│
├── Dockerfile                    ← Instructions to build the Flask app image
├── compose.yml                   ← Orchestrates Flask + PostgreSQL containers
└── README.md                     ← Project overview and quick-start guide
```

---

## 2. The Request Lifecycle

Before reading individual files, understand how a single HTTP request flows
through the entire application. This is the thread that connects every file.

```
Browser
  │
  │  GET /  (or POST /create, GET /view/3, etc.)
  │
  ▼
Flask (run.py starts it, gunicorn runs it in production)
  │
  │  Flask checks its URL routing table
  │
  ▼
routes.py  ← finds the matching @route decorator
  │
  │  Needs data? → queries the database
  │
  ▼
models.py  ← Item.query.all()  or  db.session.add(new_item)
  │
  │  SQLAlchemy sends SQL to PostgreSQL
  │
  ▼
PostgreSQL  ← returns rows
  │
  │  Back in routes.py: pass data to the template
  │
  ▼
templates/index.html  ← Jinja2 fills in {{ items }} and renders HTML
  │
  ▼
Browser receives full HTML page
```

**The key insight:** Flask, SQLAlchemy, and Jinja2 are all in the same process.
The browser never talks to the database directly — always through Flask.

---

## 3. run.py — The Entry Point

```python
from dotenv import load_dotenv
load_dotenv()                         # Must be FIRST — loads .env before anything else

import os
from app import create_app

app = create_app()                    # Build the Flask app using the factory

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 5000)))
```

### What `run.py` does

`run.py` is the **entry point** — the first file Python executes when you
start the application. It has three responsibilities:

1. **Load `.env`** — `load_dotenv()` reads the `.env` file and injects every
   variable into `os.environ`. This MUST happen before `create_app()` is called,
   because `config.py` reads `os.environ.get('DATABASE_URL')` during app creation.

2. **Build the app** — calls `create_app()` from `app/__init__.py`. This
   returns a fully configured Flask application object.

3. **Start the server** — `app.run(host='0.0.0.0', ...)` starts Flask's
   built-in development server. This line only runs when you execute
   `python run.py` directly (the `if __name__ == '__main__'` guard prevents
   it from running when imported by gunicorn).

### Why `host='0.0.0.0'` matters

By default, Flask binds to `127.0.0.1` (localhost only). With `0.0.0.0`,
it listens on ALL network interfaces — required for Docker and any
remote access.

### The `if __name__ == '__main__'` guard

```python
if __name__ == '__main__':    # True when: python run.py
    app.run(...)              # False when: gunicorn run:app (imports run.py as a module)
```

When gunicorn runs `gunicorn run:app`, it **imports** `run.py` as a module
and uses the `app` object directly. It does NOT call `app.run()` — gunicorn
has its own server loop. The guard prevents the development server from
starting when gunicorn is in charge.

### DevOps impact of run.py

| Context | Command | What happens |
|---|---|---|
| Bare-metal dev | `python run.py` | Loads `.env`, starts dev server on PORT |
| Docker (dev) | `python run.py` | Same — but `.env` is injected via `compose.yml` |
| Docker (prod) | `gunicorn run:app` | Imports `app` from `run.py`, skips `app.run()` |
| gunicorn CMD | `run:app` format | `run` = module name (run.py), `app` = variable name |

---

## 4. config.py — Environment Configuration

```python
import os

class Config:
    SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL')
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    @staticmethod
    def validate():
        if not os.environ.get('DATABASE_URL'):
            raise EnvironmentError(
                "DATABASE_URL environment variable is not set. "
                "Copy .env.example to .env and fill in your values."
            )
```

### What `config.py` does

`config.py` is a **configuration bridge** between environment variables and
Flask's internal settings. It translates environment variables into the
exact key names that Flask and its extensions expect.

### SQLALCHEMY_DATABASE_URI

This is the **exact key name Flask-SQLAlchemy looks for** in `app.config`.
If this key is missing or `None`, SQLAlchemy will not know which database
to connect to and will raise an error.

The value must follow this format:
```
postgresql://username:password@host:port/database_name
               │         │       │     │        │
               │         │       │     │        └─ database name
               │         │       │     └─ PostgreSQL port (default 5432)
               │         │       └─ hostname (localhost or Docker service name)
               │         └─ password
               └─ username
```

### SQLALCHEMY_TRACK_MODIFICATIONS

A Flask-SQLAlchemy setting. When `True`, SQLAlchemy tracks every object
change in memory to emit signals — adds overhead and memory usage with
no benefit unless you use Flask-SQLAlchemy's event system. Always `False`.

### The `validate()` method

Called at app startup (inside `create_app()` in `__init__.py`).
Raises a clear `EnvironmentError` if `DATABASE_URL` is not set, rather
than allowing the app to start in a broken state and crash later with
a cryptic database connection error.

### Why no hardcoded fallback

The original forked code had:
```python
SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL') or \
    'postgresql://root:root@localhost/my_database'
```

This is dangerous — the `or` fallback means if `DATABASE_URL` is missing,
the app silently connects to a hardcoded database with hardcoded credentials.
Committing this to a public repo exposes those credentials forever in Git history.
The current code removes the fallback and fails loudly instead.

### DevOps impact of config.py

- `DATABASE_URL` **must** be set before the app starts
- Bare-metal: set in `.env`, read by `python-dotenv` via `run.py`
- Docker: set in `compose.yml` `environment` block (overrides `env_file`)
- CI/CD: set as pipeline secret / environment variable
- If this variable is missing, the app refuses to start — this is intentional

---

## 5. app/__init__.py — Application Factory

```python
from flask import Flask
from config import Config
from app.models import db

def create_app():
    Config.validate()             # Fail fast if DATABASE_URL is not set

    app = Flask(__name__)
    app.config.from_object(Config)  # Load SQLALCHEMY_DATABASE_URI etc. into app

    db.init_app(app)              # Register db with this app instance

    from app.routes import main
    app.register_blueprint(main)  # Register the URL routes

    with app.app_context():
        db.create_all()           # Create tables if they don't exist

    return app
```

### What `__init__.py` does

`__init__.py` in the `app/` directory does two things:

1. **Makes `app/` a Python package.** Without this file, `from app import create_app`
   would raise `ModuleNotFoundError`. Python requires `__init__.py` to treat a
   directory as an importable package.

2. **Contains the Application Factory.** The `create_app()` function builds
   and returns a fully configured Flask app. This pattern (called the
   Application Factory pattern) is the standard way to structure Flask apps.

### Why Application Factory instead of a global `app`?

Without factory:
```python
# app/__init__.py (anti-pattern)
app = Flask(__name__)     # Created at import time
app.config[...] = ...
```

Problem: the app is created when the module is first imported. You cannot
create two separate app instances (e.g., one for testing with a different
config). Tests would all share one global state.

With factory:
```python
def create_app():
    app = Flask(__name__)   # Created fresh each time create_app() is called
    return app
```

Now `tests/test_app.py` can call `create_app()` independently, configure
a test database, and run tests without touching the production database.

### `app.config.from_object(Config)`

This copies every uppercase attribute from the `Config` class into Flask's
`app.config` dictionary. So `Config.SQLALCHEMY_DATABASE_URI` becomes
`app.config['SQLALCHEMY_DATABASE_URI']`.

### `db.create_all()`

Inspects all classes that inherit from `db.Model` (i.e., `Item` in `models.py`)
and creates the corresponding database tables if they don't already exist.

**Important:** `create_all()` is non-destructive — it NEVER modifies or
drops existing tables. It only creates missing ones. This means:
- First run: creates the `item` table
- Subsequent runs: finds the table already exists, does nothing
- Schema changes: does NOT apply them — use Flask-Migrate for that

### Blueprint registration

```python
from app.routes import main       # Import the Blueprint object
app.register_blueprint(main)     # Register its routes with the app
```

A Blueprint is a collection of routes defined in `routes.py`. Registering
it makes those routes (`/`, `/create`, `/view/<id>`, etc.) active in the app.

---

## 6. app/models.py — Database Schema

```python
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()                 # Single instance — imported everywhere else

class Item(db.Model):
    id          = db.Column(db.Integer, primary_key=True)
    name        = db.Column(db.String(80),  nullable=False)
    description = db.Column(db.String(200), nullable=False)

    def __repr__(self):
        return f'<Item {self.name}>'
```

### What `models.py` does

`models.py` defines **what the database looks like** in Python code.
Each class that inherits from `db.Model` maps directly to one table in
the PostgreSQL database.

### The `db = SQLAlchemy()` instance

This is the **single most important line** in the entire codebase.

`db` is the SQLAlchemy extension object — it is the bridge between
Flask and the database. It:
- Manages database connections
- Provides `db.Model` as the base class for all table definitions
- Exposes `db.session` for querying and committing data
- Must be registered with the Flask app via `db.init_app(app)` before use

**Rule:** `db = SQLAlchemy()` must exist **exactly once**. Every other
file (`routes.py`, `__init__.py`, `tests/`) must import `db` FROM here.
Creating a second `db = SQLAlchemy()` anywhere causes:
```
RuntimeError: The current Flask app is not registered with this SQLAlchemy instance.
```

### The `Item` model — mapping to a PostgreSQL table

```python
class Item(db.Model):              # db.Model = SQLAlchemy's base class for tables
    id = db.Column(db.Integer, primary_key=True)
```

This creates (via `db.create_all()`) a table named `item` with these columns:

| Python attribute | SQL column | PostgreSQL type | Constraint |
|---|---|---|---|
| `id` | `id` | `INTEGER` | PRIMARY KEY, auto-increment |
| `name` | `name` | `VARCHAR(80)` | NOT NULL |
| `description` | `description` | `VARCHAR(200)` | NOT NULL |

You can verify this inside the PostgreSQL container:
```bash
docker exec -it postgres-db psql -U <user> -d <db>
\d item          # Describe the item table
SELECT * FROM item;   # View all rows
```

### `nullable=False`

Tells SQLAlchemy to add `NOT NULL` constraint to the column. If you try
to insert a row without providing a value for `name` or `description`,
the database will reject it with an `IntegrityError`.

### `__repr__`

Python's representation method. Used in logs and the Python shell.
`print(item)` shows `<Item Tomatoes>` instead of `<app.models.Item object at 0x...>`.

---

## 7. app/routes.py — URL Routing and Business Logic

```python
from flask import Blueprint, render_template, request, redirect, url_for
from .models import db, Item

main = Blueprint('main', __name__)

@main.route('/')
def index():
    items = Item.query.all()
    return render_template('index.html', items=items)
```

### What `routes.py` does

`routes.py` defines **what happens when a specific URL is requested**.
Each `@main.route(...)` decorator ties a URL pattern to a Python function
that handles that request.

### Blueprint

```python
main = Blueprint('main', __name__)
```

A Blueprint is a **group of related routes** that can be registered with
the Flask app as a unit. This project uses one blueprint called `main`
that contains all routes.

Benefits of blueprints over defining routes directly on `app`:
- Routes can be defined in separate files without importing `app` directly
  (avoids circular imports)
- In larger projects, you can have `blueprints/auth.py`, `blueprints/api.py`,
  `blueprints/admin.py` etc. — each registered separately

### The full route table

| URL | Method | Function | What it does |
|---|---|---|---|
| `/` | GET | `index()` | Fetches all items, renders `index.html` |
| `/create` | GET | `create()` | Shows the create form (`create.html`) |
| `/create` | POST | `create()` | Reads form data, inserts new `Item`, redirects to `/` |
| `/view/<id>` | GET | `view_item(id)` | Fetches one item by ID, renders `view.html` |
| `/edit/<id>` | GET | `edit_item(id)` | Shows edit form pre-filled with item data |
| `/edit/<id>` | POST | `edit_item(id)` | Updates item in DB, redirects to `/` |
| `/delete/<id>` | GET | `delete_item(id)` | Deletes item from DB, redirects to `/` |

### How `render_template` works

```python
return render_template('index.html', items=items)
```

Flask looks for `index.html` inside `app/templates/`. Jinja2 renders
the template, substituting `{{ items }}` and other placeholders with
the actual Python data. The result is a fully rendered HTML string
sent back to the browser.

### The POST-Redirect-GET pattern

```python
@main.route('/create', methods=['GET', 'POST'])
def create():
    if request.method == 'POST':
        ...         # Save to database
        return redirect(url_for('main.index'))  # Redirect to GET /
    return render_template('create.html')       # Show the form
```

After a form submission (POST), the app **redirects** to a GET request
instead of rendering directly. Why:
- If the browser refreshes after a POST, it would re-submit the form
  (duplicate insert)
- Redirect causes the browser to make a new GET request — safe to refresh

### `get_or_404(item_id)`

```python
item = Item.query.get_or_404(item_id)
```

Fetches the item with the given primary key. If it doesn't exist,
Flask automatically returns an HTTP 404 response. You never need to
write `if item is None: return 404` manually.

### This file is the key indicator of architecture type

```python
# This project — 2-tier — Flask renders HTML
return render_template('index.html', items=items)   # ← Jinja2 template

# 3-tier API — Flask returns JSON only
return jsonify([{'id': i.id, 'name': i.name} for i in items])  # ← JSON
```

If you see `render_template` anywhere in `routes.py` → the project is 2-tier.
If you see only `jsonify` → it is an API backend (3-tier).

---

## 8. app/templates/ — Jinja2 HTML Templates

```
app/templates/
├── layout.html     ← Base template
├── index.html      ← extends layout.html
├── create.html     ← extends layout.html
├── view.html       ← extends layout.html
├── edit.html       ← extends layout.html
├── delete.html     ← extends layout.html
└── update.html     ← extends layout.html
```

### What templates do

Templates are **HTML files with Jinja2 placeholders**. Flask's
`render_template()` fills in the placeholders with real Python data
before sending the HTML to the browser.

### layout.html — The Base Template

`layout.html` is the master template that defines the page structure
shared by ALL pages: the `<html>` tag, `<head>` with CSS links,
navigation bar, and footer.

All other templates start with:
```html
{% extends 'layout.html' %}
{% block content %}
  <!-- page-specific HTML here -->
{% endblock %}
```

This means changing the navigation bar or adding a new CSS file in
`layout.html` automatically applies to every page — you change one
file instead of seven.

### Jinja2 syntax

| Syntax | Purpose | Example |
|---|---|---|
| `{{ variable }}` | Output a value | `{{ item.name }}` |
| `{% for x in y %}` | Loop | `{% for item in items %}` |
| `{% if condition %}` | Conditional | `{% if items %}` |
| `{% extends 'x' %}` | Inherit from base template | `{% extends 'layout.html' %}` |
| `{% block name %}` | Define a replaceable region | `{% block content %}` |
| `{{ url_for('main.index') }}` | Generate a URL from route name | Links and form actions |

### Why templates are in `app/templates/` not the project root

Flask looks for templates in a `templates/` folder relative to where
the Flask app object was created. Since `Flask(__name__)` is called
inside `app/__init__.py`, Flask looks in `app/templates/` automatically.

### DevOps impact

- Templates are **part of the application image** — copied in via `COPY . .`
  in the Dockerfile
- They are **read at runtime**, not compiled — changing a template requires
  rebuilding the container (or mounting as a volume during development)
- They contain NO secrets — safe to commit to Git

---

## 9. app/static/ — CSS, JavaScript, Images

```
app/static/
└── css/
    └── style.css
```

### What `static/` contains

The `static/` folder holds files that are served **directly to the browser
without any processing**. Flask does not render or modify them.

- CSS stylesheets
- JavaScript files
- Images, fonts, icons

### How static files are referenced in templates

```html
<link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
```

`url_for('static', ...)` generates the correct URL (`/static/css/style.css`)
regardless of where the app is mounted. Never hardcode `/static/...` paths.

### In production — should Nginx serve static files?

In development, Flask's built-in server serves static files directly.
In production, it is better practice to let **Nginx serve static files**
and only forward dynamic requests to gunicorn. This is because:
- Nginx is far more efficient at serving files than Python
- Reduces load on gunicorn worker processes

This is what Approach B in `Understand-Dockerization.md` implements.

---

## 10. requirements.txt — Python Dependencies

```
blinker==1.8.2
click==8.1.7
Flask==3.0.3
Flask-SQLAlchemy==3.1.1
gunicorn==22.0.0
itsdangerous==2.2.0
Jinja2==3.1.4
MarkupSafe==2.1.5
psycopg2-binary==2.9.9
python-dotenv==1.0.1
SQLAlchemy==2.0.32
Werkzeug==3.0.3
```

### What `requirements.txt` is

The exact list of Python packages the app needs, pinned to specific
versions. `pip install -r requirements.txt` installs all of them.

### Key packages and their roles

| Package | Role | DevOps impact |
|---|---|---|
| `Flask` | Web framework — routing, request/response handling | Core runtime dep |
| `Flask-SQLAlchemy` | SQLAlchemy integration for Flask | Needs DB connection |
| `SQLAlchemy` | ORM — translates Python classes to SQL | Installed as Flask-SQLAlchemy dep |
| `psycopg2-binary` | PostgreSQL driver — allows Python to connect to Postgres | **No build tools needed** |
| `gunicorn` | Production WSGI server | Used in Dockerfile CMD |
| `python-dotenv` | Reads `.env` file into `os.environ` | Used in `run.py` |
| `Jinja2` | Template engine — renders HTML with Python data | Installed as Flask dep |
| `Werkzeug` | WSGI utilities — request/response objects, routing | Installed as Flask dep |
| `blinker` | Signal library for Flask events | Installed as Flask dep |

### Version pinning — why exact versions matter

Pinning to `Flask==3.0.3` instead of `Flask` ensures:
- The image built today is identical to the image built in 6 months
- No surprise breaking changes from upstream upgrades
- Reproducible builds across dev, CI, and production

### The `psycopg2-binary` vs `psycopg2` decision

This is visible directly in `requirements.txt` — check which one is listed.

| What you see | Dockerfile implication |
|---|---|
| `psycopg2-binary` | No system packages needed — `pip install` works on clean `python:3.12-slim` |
| `psycopg2` | Must `apt-get install gcc libpq-dev` in builder stage + `libpq5` in runtime stage |

---

## 11. .env and .env.example — Runtime Secrets

### .env — Your actual secrets (NEVER commit)

```bash
# .env  — copy from .env.example, fill in real values
DATABASE_URL=postgresql://myuser:mypassword@localhost:5432/mydb
PORT=5000
POSTGRES_USER=myuser
POSTGRES_PASSWORD=mypassword
POSTGRES_DB=mydb
```

- Loaded by `python-dotenv` at bare-metal startup (`run.py` calls `load_dotenv()`)
- Loaded by Docker Compose for variable substitution in `compose.yml`
- **MUST be in `.gitignore`** — never commit real credentials to Git
- **MUST be in `.dockerignore`** — never copy into a Docker image

### .env.example — The safe template

```bash
# .env.example  — safe to commit, shows variable names without real values
DATABASE_URL=postgresql://user:password@localhost:5432/dbname
PORT=5000
POSTGRES_USER=user
POSTGRES_PASSWORD=password
POSTGRES_DB=dbname
```

`.env.example` is committed to Git. New developers run:
```bash
cp .env.example .env
# then fill in their real values
```

### How environment variables flow through the stack

```
.env file
  │
  ├─── python-dotenv (bare-metal) ──→ os.environ ──→ config.py ──→ Flask app
  │
  └─── docker compose (containerized)
         │
         ├─ env_file: .env ──────────→ all variables into container environment
         │
         └─ environment: block ─────→ overrides DATABASE_URL with Docker hostname
                                      (replaces 'localhost' with 'db')
```

---

## 12. .gitignore — What Git Must Never Track

```
.env                ← Contains real credentials — must never be in Git history
venv/               ← Virtual environment — tens of thousands of files, regenerable
IbtisamX/           ← Your custom-named venv — same reason
__pycache__/        ← Python bytecode cache — machine-specific, regenerable
*.pyc               ← Compiled Python files — regenerable
.pytest_cache/      ← Test cache — regenerable
coverage.xml        ← Generated test coverage report — not source code
.coverage           ← Coverage data file — generated artifact
*.egg-info/         ← Package metadata — generated
.DS_Store           ← macOS finder metadata — not part of the project
```

### The most critical entry

`.env` **must always be in `.gitignore`**. If real credentials are
ever committed to a public repo, they are permanently in Git history
even after deletion. Rotating all credentials is the only safe recovery.

---

## 13. .dockerignore — What Docker Must Never Copy

```
.env                ← Never bake secrets into image layers
.git/               ← Version control metadata — not needed at runtime
venv/               ← Local virtualenv — replaced by pip install in image
IbtisamX/           ← Custom venv name — same reason
__pycache__/        ← Bytecode cache — regenerated inside container
*.pyc               ← Compiled Python — regenerated inside container
.pytest_cache/      ← Test cache — not needed in production image
tests/              ← Test code — not needed in production image
coverage.xml        ← Test artifact — not needed in production image
*.md                ← Documentation — not needed at runtime
docs/               ← Documentation folder — not needed at runtime
```

### Why .dockerignore is separate from .gitignore

| | .gitignore | .dockerignore |
|---|---|---|
| Protects from | Git history | Docker image layers |
| Used by | `git add` | `docker build` (`COPY . .` instruction) |
| Main concern | Credentials, generated files | Image size, secrets baked into layers |
| Overlap | Both exclude `.env`, `venv/`, `__pycache__/` | |
| Difference | `.gitignore` excludes `node_modules/`; `.dockerignore` excludes `tests/`, `docs/` |

---

## 14. tests/ — Automated Test Suite

```
tests/
├── __init__.py       ← Makes tests/ a Python package
└── test_app.py       ← Test cases
```

### What `tests/__init__.py` does

Makes `tests/` importable as a Python package. Allows test discovery
tools (`pytest`, `unittest discover`) to find test files.
Content is usually empty.

### What `test_app.py` tests

From the coverage output in `consoleOutput.txt`:
```
Ran 4 tests in 0.058s  — OK
Name                Stmts   Miss  Cover
app/__init__.py        12      9    25%
app/models.py           8      0   100%
tests/__init__.py       0      0   100%
tests/test_app.py      26      1    96%
TOTAL                  46     10    78%
```

4 tests covering `models.py` at 100% and the overall app at 78%.
Tests use a test database (not the production one) via a test app factory.

### DevOps impact

- Tests run in CI before building the Docker image
- `tests/` and `test_app.py` are in `.dockerignore` — not included in
  the production image (saves space, not needed at runtime)
- Coverage reports (`coverage.xml`, `.coverage`) go to SonarQube for
  code quality analysis

---

## 15. Dependency Chain — Who Imports Who

Understanding the import chain prevents circular import errors.

```
run.py
  │
  ├── dotenv (load_dotenv)         ← external package
  │
  └── app (create_app)             ← app/__init__.py
        │
        ├── flask (Flask)           ← external package
        ├── config (Config)         ← config.py
        │     └── os               ← standard library
        │
        ├── app.models (db)         ← app/models.py
        │     └── flask_sqlalchemy  ← external package
        │
        └── app.routes (main)       ← app/routes.py
              ├── flask (Blueprint, render_template, ...)
              └── .models (db, Item) ← app/models.py (SAME instance as above)
```

### The import order rule

`routes.py` is imported **inside** `create_app()`, not at the top of `__init__.py`.

```python
def create_app():
    ...
    from app.routes import main    # ← delayed import, inside the function
    app.register_blueprint(main)
```

This prevents circular imports:
- `app/__init__.py` defines `create_app`
- `app/routes.py` imports from `app.models`
- If routes were imported at the top of `__init__.py`, Python might try
  to import `routes` before `__init__.py` has finished executing

---

## 16. File Deletion Guide — What Is Optional

As a DevOps engineer inheriting a project, knowing what you can safely
delete vs. what will break the application is critical.

| File / Folder | Can delete? | Impact if deleted |
|---|---|---|
| `run.py` | ❌ No | App cannot start — `gunicorn run:app` needs this |
| `config.py` | ❌ No | `__init__.py` imports Config — breaks entirely |
| `app/__init__.py` | ❌ No | `app` becomes non-importable package — breaks entirely |
| `app/models.py` | ❌ No | No `db` or `Item` — routes and init break |
| `app/routes.py` | ❌ No | No URL handlers — app starts but serves nothing |
| `app/templates/layout.html` | ❌ No | All pages inherit from it — all pages break |
| `app/templates/index.html` | ⚠️ Sort of | `/` route breaks — `render_template` raises TemplateNotFound |
| `app/static/css/style.css` | ✅ Yes | App still works — pages just lose styling |
| `requirements.txt` | ❌ No | Docker build fails — `pip install -r` needs this |
| `.env.example` | ✅ Yes | Documentation only — app still works |
| `.gitignore` | ✅ Yes | App still works — but you risk committing secrets |
| `.dockerignore` | ✅ Yes | App still works — but image will be larger and may contain secrets |
| `tests/` | ✅ Yes | App still runs — but no automated quality checks |
| `docs/` | ✅ Yes | Documentation only — no runtime impact |
| `__pycache__/` | ✅ Yes | Python regenerates it automatically |
| `venv/` / `IbtisamX/` | ✅ Yes | Virtualenv — regenerate with `python -m venv venv` |

---

## 17. DevOps Decision Map — File → Infrastructure Impact

This is the most important section. Each file in the project forces
specific decisions about how you containerize and deploy it.

### From `requirements.txt`

| What you see | What you do in Dockerfile |
|---|---|
| `psycopg2-binary` | No apt-get needed — `pip install` works on slim |
| `psycopg2` (no -binary) | `apt-get install gcc libpq-dev` in builder, `libpq5` in runtime |
| `gunicorn` | CMD uses `gunicorn run:app` in production |
| `python-dotenv` | `load_dotenv()` handles `.env` on bare-metal; Docker Compose handles it for containers |
| `Flask` | No special setup — pure Python |

### From `run.py`

| What you see | What you do |
|---|---|
| `if __name__ == '__main__': app.run(...)` | gunicorn uses `run:app` — `app.run()` is skipped |
| `host='0.0.0.0'` | gunicorn also needs `--bind 0.0.0.0:5000` |
| `port=int(os.environ.get('PORT', 5000))` | Expose port 5000 in Dockerfile; map in compose.yml |
| `load_dotenv()` at top | Fine for bare-metal; irrelevant in Docker (env injected by compose) |

### From `config.py`

| What you see | What you do |
|---|---|
| `os.environ.get('DATABASE_URL')` | Must set `DATABASE_URL` in compose.yml environment block |
| `Config.validate()` raises if missing | Container will fail to start if `DATABASE_URL` is not set — this is intentional |
| No hardcoded fallback | You cannot skip setting the variable — no silent default |

### From `app/__init__.py`

| What you see | What you do |
|---|---|
| `db.create_all()` | Tables are created on first startup — no migration tool needed for fresh deploy |
| `db.init_app(app)` | Confirms db is initialized at runtime — not at import time |
| `Blueprint` registration | Confirms routes are loaded correctly |

### From `app/routes.py`

| What you see | What it means |
|---|---|
| `render_template(...)` | 2-tier project — Flask serves HTML — 1 Dockerfile |
| `jsonify(...)` only | 3-tier API — needs separate frontend container |
| `request.method == 'POST'` | POST routes exist — Nginx must allow POST (default: yes) |

### From `app/templates/` and `app/static/`

| What you see | What you do |
|---|---|
| Templates exist | They are copied into image via `COPY . .` — no special step needed |
| Static CSS/JS files | Flask serves them in dev; Nginx should serve them in production |

---

## 18. Bare-Metal Setup Walkthrough

This is what you saw in `consoleOutput.txt` — the manual setup sequence
that shows exactly what the app needs to run outside of Docker.

### Step 1 — Install PostgreSQL

```bash
sudo apt-get install postgresql postgresql-contrib
sudo systemctl start postgresql
```

PostgreSQL is an external process — it runs independently of Flask.

### Step 2 — Create database and user

```bash
sudo -u postgres psql
```
```sql
CREATE USER myuser WITH PASSWORD 'mypassword';
CREATE DATABASE mydb;
GRANT ALL PRIVILEGES ON DATABASE mydb TO myuser;
\c mydb
GRANT ALL PRIVILEGES ON SCHEMA public TO myuser;
```

This is exactly what the official `postgres` Docker image does automatically
when you pass `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` as
environment variables — saving you all these manual steps.

### Step 3 — Create virtual environment and install dependencies

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

The virtual environment isolates this project's packages from the system
Python. In Docker, the image itself provides this isolation — no venv needed.

### Step 4 — Set environment variables

```bash
cp .env.example .env
# Edit .env — set DATABASE_URL=postgresql://myuser:mypassword@localhost:5432/mydb
```

### Step 5 — Run the application

```bash
python run.py
# Output:
# * Serving Flask app 'app'
# * Running on http://0.0.0.0:5000
```

Flask calls `db.create_all()` on startup — the `item` table is created
automatically if it doesn't exist.

### The Docker equivalent

| Bare-metal step | Docker Compose equivalent |
|---|---|
| `apt-get install postgresql` | `image: postgres:16-alpine` in compose.yml |
| `CREATE USER`, `CREATE DATABASE` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` env vars |
| `python3 -m venv venv` + `pip install` | `RUN pip install -r requirements.txt` in Dockerfile |
| Edit `.env` | `env_file: .env` + `environment` override in compose.yml |
| `python run.py` | `CMD ["gunicorn", "run:app"]` in Dockerfile |
| Wait for PostgreSQL manually | `healthcheck` + `depends_on: condition: service_healthy` |
