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

# Copy application source code and set ownership in one layer
# chown at COPY time avoids a separate RUN chown layer (which would double the layer size)
COPY --chown=appuser:appgroup . .

# Ensure the venv binaries take priority over system Python
ENV PATH="/opt/venv/bin:$PATH"

# Default port — override at runtime via .env or compose.yml environment block.
# DATABASE_URL must be injected at runtime — never hardcoded here.
ENV PORT=5000

# Drop to non-root user before starting the process
USER appuser

# Expose the port the app listens on
EXPOSE 5000

# Health check — calls /health endpoint added in routes.py.
# start_period gives the app time to connect to the database before failures count.
# Kubernetes uses its own liveness/readiness probes — this is for Docker and Compose.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT:-5000}/health')" \
    || exit 1

# Production entrypoint: gunicorn serves the Flask app.
# Workers = (2 x CPU cores) + 1 is the standard formula; 3 is a safe default for containers.
# PORT is read from the environment — falls back to 5000 if not set.
# Shell form (sh -c) is required here so the ${PORT} variable is expanded at runtime.
CMD ["sh", "-c", "gunicorn --bind 0.0.0.0:${PORT:-5000} --workers 3 --timeout 120 run:app"]
