# ── Stage 1: Builder ─────────────────────────────────────────────────────────
# Install dependencies in a separate stage so the final image stays lean.
FROM python:3.12-slim AS builder

WORKDIR /app

# Install build dependencies required by psycopg2-binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy only requirements first to leverage Docker layer caching.
# If requirements.txt doesn't change, this layer is reused on rebuilds.
COPY requirements.txt .

# Install all Python dependencies into a local directory (not system-wide)
RUN pip install --upgrade pip \
    && pip install --prefix=/install --no-cache-dir -r requirements.txt


# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
# Start fresh from a clean slim image — no build tools, no cache.
FROM python:3.12-slim

WORKDIR /app

# Install only the runtime shared library needed by psycopg2-binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from builder stage
COPY --from=builder /install /usr/local

# Copy application source code
COPY . .

# ── Security: run as non-root user ────────────────────────────────────────────
# Never run application processes as root inside a container.
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser

# Expose the port Flask listens on (must match PORT in .env and compose.yml)
EXPOSE 5000

# Use gunicorn for production.
# 'run:app' means: import the 'app' object from run.py
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--timeout", "60", "run:app"]
