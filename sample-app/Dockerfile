# ==============================================================================
# Sample App (Django + Celery) — Multi-Stage Non-Root Container Image
# SemVer: 1.0.0
# Complies with Kubernetes Pod Security Standards (Restricted profile)
# ==============================================================================
FROM python:3.12-slim-bookworm AS builder

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# ==============================================================================
# Final Production Stage
# ==============================================================================
FROM python:3.12-slim-bookworm

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/home/appuser/.local/bin:$PATH"

# Install minimal runtime libraries for postgres & curl for healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create unprivileged user (UID 10001)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /bin/bash -m appuser

# Copy installed wheels from builder
COPY --from=builder /root/.local /home/appuser/.local
RUN chown -R appuser:appgroup /home/appuser/.local

# Copy application source code
COPY --chown=appuser:appgroup . /app

USER 10001

EXPOSE 8000

# Default command runs Gunicorn WSGI server.
# Overridden by Celery worker pods to run: celery -A config worker -l info
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--threads", "2", "config.wsgi:application"]
