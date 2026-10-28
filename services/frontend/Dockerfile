# Build context: repository root.
# The JS bundle is architecture-independent, so build it natively and only
# the nginx runtime layer is per-arch.
FROM --platform=$BUILDPLATFORM node:22-alpine AS build
WORKDIR /src
COPY services/frontend/package.json services/frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund
COPY services/frontend/ ./
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.27-alpine
ENV GATEWAY_HOST=gateway GATEWAY_PORT=8000 NODE_NAME=local
COPY services/frontend/nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /src/dist /usr/share/nginx/html
EXPOSE 8080
