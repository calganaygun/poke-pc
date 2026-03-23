FROM node:20-bookworm-slim AS build
WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-bookworm-slim AS runtime
WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends tmux ca-certificates bash jq ffmpeg python3 python3-pip build-essential ca-certificates curl

COPY package*.json ./
RUN npm ci --omit=dev

COPY --from=build /app/dist ./dist
COPY config ./config

RUN mkdir -p /root/poke-pc

ENV NODE_ENV=production
ENV MCP_HOST=0.0.0.0
ENV MCP_PORT=3000
ENV POKE_PC_STATE_DIR=/root/poke-pc

EXPOSE 3000

CMD ["node", "dist/index.js"]
