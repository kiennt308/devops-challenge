const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const app = express();
const PORT = Number(process.env.PORT) || 3000;
let isShuttingDown = false;

// Instruct HTTP/1.1 keep-alive clients (e.g. NGINX) to close sockets once shutdown starts
// so in-flight requests do not hold server.close() open after completing.
app.use((req, res, next) => {
  if (isShuttingDown) {
    res.setHeader("Connection", "close");
  }
  next();
});

const pool = new Pool({
  host: process.env.DB_HOST || "postgres",
  user: process.env.POSTGRES_USER || "postgres",
  password: process.env.POSTGRES_PASSWORD || "postgres",
  database: process.env.POSTGRES_DB || "postgres",
  port: Number(process.env.DB_PORT) || 5432,
  max: Number(process.env.DB_POOL_MAX) || 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  query_timeout: 5000,
  statement_timeout: 5000,
});

// Prevent unhandled pool errors on idle clients from crashing the Node process
pool.on("error", (err) => {
  console.error("Unexpected error on idle PostgreSQL client:", err.message);
});

const redis = new Redis({
  host: process.env.REDIS_HOST || "redis",
  port: Number(process.env.REDIS_PORT) || 6379,
  maxRetriesPerRequest: 3,
  connectTimeout: 5000,
  retryStrategy(times) {
    return Math.min(times * 100, 2000);
  },
});

// Prevent unhandled Redis connection errors from crashing the Node process
redis.on("error", (err) => {
  console.error("Redis connection error:", err.message);
});

app.get("/api/users", async (req, res) => {
  try {
    // pool.query() automatically acquires and releases a client in a finally block,
    // preventing connection leaks if a query fails or times out.
    const result = await pool.query("SELECT NOW()");

    await redis.set("last_call", Date.now());
    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    console.error("Error in GET /api/users:", err.message);
    res.status(500).json({ ok: false, error: "Internal server error" });
  }
});

// Shallow liveness endpoint (process & HTTP event loop responsiveness)
app.get("/healthz", (req, res) => {
  res.json({ status: "alive" });
});

// Deep readiness endpoint (verifies downstream PostgreSQL & Redis connectivity)
app.get("/status", async (req, res) => {
  if (isShuttingDown) {
    return res.status(503).json({ status: "shutting_down" });
  }
  try {
    await Promise.all([pool.query("SELECT 1"), redis.ping()]);
    res.json({ status: "ok", db: "up", redis: "up" });
  } catch (err) {
    console.error("Readiness check failed:", err.message);
    res.status(503).json({ status: "degraded", error: "Downstream dependency unavailable" });
  }
});

const server = app.listen(PORT, () => console.log(`API running on ${PORT}`));

// Graceful shutdown to release DB/Redis connections cleanly on container stop/restart
const shutdown = (signal) => {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`Received ${signal}, shutting down gracefully...`);

  // Force exit if draining takes longer than 8s (before Docker's 10s SIGKILL)
  const forceTimer = setTimeout(() => {
    console.error("Forced shutdown after timeout");
    process.exit(1);
  }, 8000);
  forceTimer.unref();

  if (typeof server.closeIdleConnections === "function") {
    server.closeIdleConnections();
  }

  server.close(async () => {
    try {
      await Promise.allSettled([pool.end(), redis.quit()]);
      process.exit(0);
    } catch (err) {
      console.error("Error during shutdown:", err.message);
      process.exit(1);
    }
  });
};

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
