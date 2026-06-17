# ============================================================
# Stage 1: Builder — only used to install dependencies.
# This stage is THROWN AWAY after build, so build tools
# (gcc, headers, etc.) never end up in the final image.
# ============================================================
FROM python:3.10-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir --target=/install -r requirements.txt


# ============================================================
# Stage 2: Final image — small, clean, no compilers, no root.
# ============================================================
FROM python:3.10-slim

RUN adduser --disabled-password --gecos '' appuser

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH="/install" \
    PATH="/install/bin:$PATH"

COPY --from=builder /install /install

COPY --chown=appuser:appuser . .

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/')" || exit 1

CMD ["gunicorn", "pollme.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3"]
