# Problem 3

A small platform has been deployed using Docker Compose.
Users are reporting that the API is unreliable and sometimes inaccessible.

Your task is to investigate and stabilize the system.

## Setup

Requirements:

* Docker
* Docker Compose

Run:

```bash
docker compose up --build
```

The application will be available at:
[http://localhost:8080](http://localhost:8080)

## Your Tasks

1. Identify the issues affecting the system
2. Fix them
3. Explain the root causes

## Submission

Submit a short report including:

* What problems you found
* How you diagnosed them
* The fixes you applied
* What monitoring/alerts you would add
* How you would prevent this in production

---

# Incident Investigation & Stabilization Report

## 1. Executive Summary

The platform consists of four containers orchestrated via Docker Compose: **NGINX** (reverse proxy on port `8080`), **API** (Node.js/Express application), **PostgreSQL 15**, and **Redis 7**.

Users reported that the API was inaccessible or intermittently failing. Investigation revealed **one immediate blocker** making `/api/*` completely unreachable (`502 Bad Gateway`), along with **six underlying reliability, connection-management, and orchestration flaws** that caused connection pool exhaustion, unhandled process crashes during dependency hiccups, and startup race conditions.

---

## 2. Problems Found & Root Cause Analysis

### Issue 1: NGINX Upstream Port Mismatch (Immediate `502 Bad Gateway`)
* **Location:** [`nginx/conf.d/default.conf`](nginx/conf.d/default.conf) vs [`api/src/index.js`](api/src/index.js)
* **Symptom:** Requests to `http://localhost:8080/` succeeded (`200 OK`), but every request to `http://localhost:8080/api/users` immediately failed with `502 Bad Gateway` (`connect() failed (111: Connection refused) while connecting to upstream`).
* **Root Cause:** The Express server listened on port `3000` (`app.listen(3000)`), whereas NGINX was configured with `proxy_pass http://api:3001;`. Additionally, the `/status` health endpoint implemented in Express was not routed in NGINX.

### Issue 2: PostgreSQL Connection Pool Leak on Query Error
* **Location:** [`api/src/index.js`](api/src/index.js) (`GET /api/users`)
* **Symptom:** After transient database errors or query timeouts, the API stopped responding to all subsequent `/api/users` requests and hung indefinitely.
* **Root Cause:** The route handler manually checked out a client using `const db = await pool.connect()`, ran `await db.query(...)`, and called `db.release()` inside the `try` block **without a `finally` block**:
  ```javascript
  const db = await pool.connect();
  const result = await db.query("SELECT NOW()");
  db.release(); // Never reached if db.query() throws!
  ```
  Whenever `db.query()` threw an exception, execution jumped to `catch (err)` without releasing the client back to `pg.Pool`. Because `pg.Pool` defaults to `max: 10` connections, just 10 failed queries permanently exhausted the pool, deadlocking all future requests.

### Issue 3: Unhandled Error Events on `pg.Pool` and `ioredis` Crashing Node.js
* **Location:** [`api/src/index.js`](api/src/index.js)
* **Symptom:** If PostgreSQL or Redis restarted or dropped an idle connection, the `api` container crashed with an `Unhandled 'error' event` exception and stayed down.
* **Root Cause:** In Node.js, both `pg.Pool` and `ioredis` are `EventEmitter` instances. When an idle client in the pool encounters a network partition or backend restart, `pg.Pool` emits an `'error'` event. Without a registered `pool.on('error', ...)` or `redis.on('error', ...)` listener, Node.js treats the event as an uncaught exception and terminates the process. Combined with no `restart:` policy in [`docker-compose.yml`](docker-compose.yml), a brief network blip caused permanent outage.

### Issue 4: Startup Race Conditions & Missing Restart Policies
* **Location:** [`docker-compose.yml`](docker-compose.yml)
* **Symptom:** During cold starts (`docker compose up`), early requests failed or containers exited unexpectedly.
* **Root Cause:**
  1. `depends_on: [postgres, redis]` without `condition: service_healthy` only waits for container processes to start, **not** for PostgreSQL (`pg_isready`) or Redis (`redis-cli ping`) to finish initialization and accept TCP connections.
  2. None of the services defined a `restart:` policy (`restart: unless-stopped`), meaning any crash left the service permanently offline.

### Issue 5: Unmounted & Overly Restrictive PostgreSQL Configuration (`init.sql`) and Ephemeral Storage
* **Location:** [`postgres/init.sql`](postgres/init.sql) and [`docker-compose.yml`](docker-compose.yml)
* **Symptom:** Database settings were either ignored or, when applied, throttled connection capacity (`max_connections = 20`); container recreation wiped all database and Redis state.
* **Root Cause:**
  1. `postgres/init.sql` set `ALTER SYSTEM SET max_connections = 20;`, which leaves only ~17 connections for applications after Postgres superuser reservations (`superuser_reserved_connections = 3`). If scaling past a single API replica, `FATAL: sorry, too many clients already` occurs immediately.
  2. `postgres/init.sql` was not mounted into `/docker-entrypoint-initdb.d/` in `docker-compose.yml`, and neither `postgres` nor `redis` had persistent named volumes configured.

### Issue 6: Empty `.env` and `nginx/nginx.conf` Files & Hardcoded Credentials
* **Location:** [`.env`](.env), [`nginx/nginx.conf`](nginx/nginx.conf), [`api/src/index.js`](api/src/index.js)
* **Symptom:** Configuration drift and lack of upstream request timing visibility in NGINX logs.
* **Root Cause:** `.env` and `nginx/nginx.conf` were 0-byte files in the repository. Database credentials (`user`, `password`, `database`) and ports were hardcoded in `api/src/index.js` instead of reading from environment variables.

### Issue 7: Shallow Health Check & Missing Graceful Shutdown
* **Location:** [`api/src/index.js`](api/src/index.js) and [`api/Dockerfile`](api/Dockerfile)
* **Symptom:** `GET /status` returned `200 {"status": "ok"}` even when PostgreSQL and Redis were completely unreachable. Furthermore, stopping or redeploying the `api` container abruptly severed active connections and leaked PostgreSQL backend sessions until TCP timeout.
* **Root Cause:** `/status` was a static response that did not verify downstream dependencies, and `index.js` lacked `SIGTERM`/`SIGINT` handlers to drain HTTP requests (`server.close()`) and close `pool.end()` / `redis.quit()`.

---

## 3. How the Issues Were Diagnosed

1. **Configuration & Static Code Audit:**
   * Inspected [`docker-compose.yml`](docker-compose.yml), [`nginx/conf.d/default.conf`](nginx/conf.d/default.conf), and [`api/src/index.js`](api/src/index.js).
   * Immediately spotted the port mismatch (`proxy_pass http://api:3001` vs `app.listen(3000)`).
   * Checked file sizes across the directory (`find src/problem3 -type f`) and noticed 0-byte `.env` and `nginx/nginx.conf` files, plus an unmounted `postgres/init.sql`.
2. **Code Path & Failure-Mode Tracing:**
   * Traced execution inside `app.get("/api/users")` when `db.query()` or `redis.set()` throws an error; verified that `db.release()` is skipped on exception, causing `pg.Pool` exhaustion after `max` (10) errors.
   * Checked `pg.Pool` and `ioredis` initialization for error event listeners, connection timeouts (`connectionTimeoutMillis`, `connectTimeout`, `maxRetriesPerRequest`), and `SIGTERM` signal handling.
3. **Orchestration Verification:**
   * Validated the resolved compose specification using `docker compose config` to verify environment variable interpolation, volume mounts, and healthcheck dependency chains.

---

## 4. Fixes Applied

| Component | File(s) Modified | Summary of Changes |
| :--- | :--- | :--- |
| **NGINX Reverse Proxy** | [`nginx/conf.d/default.conf`](nginx/conf.d/default.conf), [`nginx/nginx.conf`](nginx/nginx.conf) | Fixed upstream port from `3001` to `3000`; configured Docker embedded DNS resolution (`resolver 127.0.0.11 valid=10s` with `$api_upstream` variable in `proxy_pass`) so NGINX dynamically re-resolves `api` if the container is recreated with a new IP; exposed `/healthz` (shallow liveness) and `/status` (deep readiness); configured explicit `proxy_connect_timeout`, `proxy_read_timeout`, and `proxy_next_upstream`; populated `nginx.conf` with upstream latency logging (`rt`, `uct`, `uht`, `urt`). |
| **API Service (Node.js)** | [`api/src/index.js`](api/src/index.js), [`api/Dockerfile`](api/Dockerfile), [`api/.dockerignore`](api/.dockerignore) | Replaced manual `pool.connect()`/`db.release()` with `pool.query()` to guarantee automatic client release; configured pool bounds (`max: 10`, `idleTimeoutMillis: 30000`, `connectionTimeoutMillis: 5000`, `query_timeout: 5000`, `statement_timeout: 5000`); attached `pool.on('error')` and `redis.on('error')` listeners; separated shallow liveness (`/healthz`) from deep readiness (`/status` verifying Postgres `SELECT 1`, Redis `PING`, and `!isShuttingDown`); added `SIGTERM`/`SIGINT` graceful shutdown with `Connection: close` drain middleware, `closeIdleConnections()`, and an 8s forced-exit guard; sanitized error responses to prevent internal error leaks; added `tini` PID 1 init entrypoint, dynamic `${PORT:-3000}` `HEALTHCHECK`, non-root `node:node` user, and `.dockerignore`. |
| **Database & Cache** | [`postgres/init.sql`](postgres/init.sql), [`docker-compose.yml`](docker-compose.yml) | Enforced Postgres `max_connections=100` both declaratively via `command: ["postgres", "-c", "max_connections=100"]` (so it applies even across existing volumes) and in `init.sql`; added persistent volumes (`pgdata`, `redisdata`), Redis AOF persistence with auto-rewrite (`--appendonly yes`, `--auto-aof-rewrite-percentage 100`), and memory bounds (`--maxmemory 256mb --maxmemory-policy allkeys-lru`). |
| **Compose & Network Isolation** | [`docker-compose.yml`](docker-compose.yml), [`.env`](.env) | Populated `.env`; isolated network tiers into `frontend_net` (`nginx` <-> `api`) and air-gapped `backend_net` (`internal: true` for `api` <-> `postgres`/`redis`); enabled `init: true` on `api`; added isolated `healthcheck` definitions for all 4 services using `$${PORT:-3000}`; enforced `depends_on` with `condition: service_healthy`; added `restart: unless-stopped` to all services. |

---

## 5. Monitoring & Alerting Recommendations

To detect and diagnose issues before users are impacted, we should instrument the stack across four layers (Golden Signals: Latency, Traffic, Errors, Saturation):

1. **Edge / NGINX Metrics (`nginx-prometheus-exporter` & Access Logs):**
   * **Alert (Critical):** HTTP `5xx` error rate > `1%` over 2 minutes.
   * **Alert (Warning):** Upstream response time (`$upstream_response_time`) `p95 > 250ms` or `p99 > 500ms` over 5 minutes.
2. **API Application Metrics (`prom-client` / OpenTelemetry):**
   * **Connection Pool Saturation:** Export `pg_pool_total_count`, `pg_pool_idle_count`, and `pg_pool_waiting_count`.
   * **Alert (Warning):** `pg_pool_waiting_count > 0` sustained for 1 minute (indicates pool exhaustion or slow queries).
   * **Process Stability:** Alert on container restart count (`changes(container_start_time_seconds[15m]) > 0`) and Node.js event loop lag > `100ms`.
3. **PostgreSQL Metrics (`postgres_exporter`):**
   * **Alert (Warning):** Active connections (`pg_stat_activity`) > `75%` of `max_connections`.
   * **Alert (Critical):** `pg_up == 0` or deadlocks / slow queries exceeding `1s`.
4. **Redis Metrics (`redis_exporter`):**
   * **Alert (Warning):** Memory usage (`used_memory / maxmemory`) > `80%`, rejected connections > `0`, or `redis_up == 0`.
5. **Synthetic Blackbox Probing (`blackbox_exporter`):**
   * Probe `http://localhost:8080/status` and `http://localhost:8080/api/users` every 15 seconds; alert immediately if status code != `200`.

---

## 6. How to Prevent This in Production

1. **Automated Integration & Smoke Tests in CI/CD:**
   * Run `docker compose up -d --wait` inside the CI pipeline on every Pull Request and execute automated smoke tests against `/status` and `/api/users` (including fault-injection tests that verify behavior when a query fails). A port mismatch like `3001` vs `3000` would fail the PR build immediately.
2. **Static Analysis & Linting Rules:**
   * Enforce ESLint rules and code review checklists that ban raw `pool.connect()` unless paired with a `try / finally { client.release() }` block (or mandate `pool.query()` for single statements and a dedicated transaction helper `withTransaction(pool, fn)` for multi-statement transactions).
3. **Centralized Connection Pooling (PgBouncer / RDS Proxy):**
   * Place **PgBouncer** (in transaction pooling mode) between the Node.js API replicas and PostgreSQL so that scaling out API instances never exhausts PostgreSQL `max_connections`.
4. **Infrastructure & Configuration Validation:**
   * Use schema validation on startup (e.g., `envalid` or `zod` in Node.js, `nginx -t` in CI, `docker compose config --quiet`) so missing environment variables or empty config files fail fast with clear error messages at build time.
5. **Zero-Downtime Rolling Deployments & Readiness Gates:**
   * In production orchestrators (ECS / Kubernetes), separate **Liveness Probes** (shallow check: is the Node process alive?) from **Readiness Probes** (deep check: `/status` verifying DB and Redis connectivity) so traffic is only routed to instances that have established healthy downstream connections.
