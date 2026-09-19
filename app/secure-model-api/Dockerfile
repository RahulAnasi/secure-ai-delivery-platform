# syntax=docker/dockerfile:1.7

ARG PYTHON_IMAGE=python:3.13.15-slim-bookworm


FROM ${PYTHON_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

COPY requirements.txt ./requirements.txt

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install \
        --no-cache-dir \
        --requirement requirements.txt

COPY src ./src
COPY scripts/encrypt_model.py ./scripts/encrypt_model.py

ENV PYTHONPATH=/build/src

RUN --mount=type=secret,id=model_key,required=true \
    --mount=type=secret,id=model_source,required=true \
    /opt/venv/bin/python scripts/encrypt_model.py \
        --input /run/secrets/model_source \
        --key-file /run/secrets/model_key \
        --output /build/output/model.enc


FROM ${PYTHON_IMAGE} AS runtime

ARG APP_UID=10001
ARG APP_GID=10001

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app/src \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    APP_ENV=production \
    LOG_LEVEL=INFO \
    ENCRYPTED_MODEL_PATH=/app/models/model.enc \
    DECRYPTED_MODEL_PATH=/dev/shm/model.bin \
    MODEL_KEY_FILE=/run/secrets/model-key

RUN groupadd --gid "${APP_GID}" app \
    && useradd \
        --uid "${APP_UID}" \
        --gid "${APP_GID}" \
        --no-create-home \
        --home-dir /nonexistent \
        --shell /usr/sbin/nologin \
        app

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=10001:10001 src /app/src
COPY --from=builder --chown=10001:10001 \
    /build/output/model.enc \
    /app/models/model.enc

USER 10001:10001

EXPOSE 8000

HEALTHCHECK \
    --interval=10s \
    --timeout=3s \
    --start-period=10s \
    --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).read()"]

CMD ["uvicorn", "secure_model_api.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]