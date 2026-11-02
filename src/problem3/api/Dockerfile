FROM node:20-alpine

RUN apk add --no-cache tini

WORKDIR /app

COPY --chown=node:node package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY --chown=node:node src ./src

USER node

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT:-3000}/healthz || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/index.js"]
