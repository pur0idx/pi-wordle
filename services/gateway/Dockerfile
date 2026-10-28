# Build context: repository root.
FROM python:3.12-alpine AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY services/gateway/requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt
COPY services/gateway/app ./app
USER nobody
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]

# docker build --target test -f services/gateway/Dockerfile .
FROM runtime AS test
USER root
COPY services/gateway/requirements-dev.txt ./
RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements-dev.txt
COPY services/gateway/tests ./tests
RUN python -m pytest -q tests
