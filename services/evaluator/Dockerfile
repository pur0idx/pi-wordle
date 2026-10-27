# Build context: repository root.
FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY services/evaluator/package.json services/evaluator/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --no-audit --no-fund
COPY services/evaluator/src ./src
USER node
EXPOSE 8080
CMD ["node", "src/server.js"]
