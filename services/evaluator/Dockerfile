# Build context: repository root.
FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY services/evaluator/package.json services/evaluator/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY services/evaluator/src ./src
USER node
EXPOSE 8080
CMD ["node", "src/server.js"]
