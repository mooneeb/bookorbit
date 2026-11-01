FROM node:24-bookworm-slim@sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c AS node
FROM pgvector/pgvector:pg18

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN node /usr/local/lib/node_modules/npm/bin/npm-cli.js install -g pnpm@11.28.9
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY patches ./patches
COPY packages/types/package.json ./packages/types/package.json
COPY packages/plugin-api/package.json ./packages/plugin-api/package.json
COPY server/package.json ./server/package.json
COPY client/package.json ./client/package.json
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile --filter server... --ignore-scripts --network-concurrency=8 --child-concurrency=2
COPY packages ./packages
COPY server ./server
COPY native/QAFixtures ./native/QAFixtures
COPY native/scripts/qa-profile-entrypoint.sh ./native/scripts/qa-profile-entrypoint.sh
RUN pnpm --config.verify-deps-before-run=false --filter @bookorbit/types build && pnpm --config.verify-deps-before-run=false --filter @bookorbit/plugin-api build
ARG QA_SOURCE_COMMIT=uncommitted
ENV QA_SOURCE_COMMIT=${QA_SOURCE_COMMIT}
LABEL org.opencontainers.image.revision=${QA_SOURCE_COMMIT}
ENTRYPOINT ["bash", "/app/native/scripts/qa-profile-entrypoint.sh"]
