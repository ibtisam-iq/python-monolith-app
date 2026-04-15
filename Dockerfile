# ──────────────────────────────────────────────────────────────────────────────
# Stage 1 — Builder
# Installs all Python dependencies into an isolated virtual environment.
# This stage is discarded after the build — no build tools leak into the final image.
# ──────────────────────────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app

# Install dependencies first (cached layer — only invalidated when requirements.txt changes)
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip --no-cache-dir \
    && /opt/venv/bin/pip install -r requirements.txt --no-cache-dir

# ──────────────────────────────────────────────────────────────────────────────
# Stage 2 — Runtime
# Copies only the venv and application code. No pip, no build tools, minimal attack surface.
# ──────────────────────────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Create a non-root user — running as root inside a container is a security risk
RUN groupadd --gid 1001 appgroup \
    && useradd --uid 1001 --gid appgroup --no-create-home appuser

WORKDIR /app

# Copy the virtual environment from the builder stage
COPY --from=builder /opt/venv /opt/venv

# Copy application source code
COPY . .

# Ensure the venv binaries take priority over system Python
ENV PATH="/opt/venv/bin:$PATH"

# Environment variables with safe defaults.
# DATABASE_URL must be injected at runtime via --env-file or compose.yml — never hardcoded.
ENV PORT=5000

# Drop to non-root user before starting the process
USER appuser

# Expose the port the app listens on
EXPOSE 5000

# Production entrypoint: gunicorn serves the Flask app.
# 'run:app' refers to the 'app' object created in run.py.
# Workers = (2 x CPU cores) + 1 is the standard formula; 3 is a safe default for containers.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "--timeout", "120", "run:app"]
