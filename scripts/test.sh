#!/usr/bin/env bash
# Run every service's unit tests. Go and Node run natively if installed;
# the Python services run inside their Docker `test` stage.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> word-service (go test)"
if command -v go >/dev/null; then (cd services/word-service && go test ./...)
else docker run --rm -v "$PWD/services/word-service:/src" -w /src golang:1.24-alpine go test ./...; fi

echo "==> evaluator (node --test)"
if command -v node >/dev/null; then (cd services/evaluator && node --test test/)
else docker run --rm -v "$PWD:/repo" -w /repo/services/evaluator node:22-alpine node --test test/; fi

for svc in gateway hint-engine; do
  echo "==> $svc (pytest in docker)"
  docker build -q --target test -f "services/$svc/Dockerfile" . >/dev/null && echo "ok"
done
echo "All tests passed."
