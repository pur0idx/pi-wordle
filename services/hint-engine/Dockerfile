# Build context: repository root.
#
# The pattern matrix is computed in a stage pinned to the build machine's
# native platform, so a multi-arch build does not grind through it under
# QEMU. The .npz output is architecture-independent and is copied into the
# arm64/amd64 runtime image.
ARG PYTHON=python:3.12-slim

FROM --platform=$BUILDPLATFORM ${PYTHON} AS precompute
WORKDIR /app
RUN pip install --no-cache-dir numpy==2.2.1
COPY services/hint-engine/app ./app
COPY data/words ./words
RUN python -m app.precompute words /app/patterns.npz

FROM ${PYTHON} AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY services/hint-engine/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY services/hint-engine/app ./app
COPY data/words ./words
COPY --from=precompute /app/patterns.npz ./patterns.npz
USER nobody
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]

# docker build --target test -f services/hint-engine/Dockerfile .
FROM runtime AS test
USER root
COPY services/hint-engine/requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY services/hint-engine/tests ./tests
COPY data/test-vectors.json ./tests/test-vectors.json
RUN python -m pytest -q tests
