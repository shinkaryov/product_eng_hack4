FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PATH="/opt/venv/bin:$PATH"

COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

RUN apt-get update && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-ces && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first, for layer caching
COPY pyproject.toml uv.lock* ./
RUN uv sync --no-dev --no-install-project

COPY src ./src
COPY migrations ./migrations
COPY alembic.ini ./
RUN uv sync --no-dev

# Unprivileged runtime user; /data/files is the private document volume
RUN useradd --create-home --uid 1000 app \
    && mkdir -p /data/files \
    && chown -R app:app /data
USER app

EXPOSE 8000
CMD ["uvicorn", "vault.main:app", "--host", "0.0.0.0", "--port", "8000"]
