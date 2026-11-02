-- Raise max_connections from the overly restrictive 20 to 100 in postgresql.auto.conf.
-- Because max_connections has 'postmaster' context in PostgreSQL, it only takes effect
-- upon server start/restart (which the official postgres entrypoint performs after
-- finishing /docker-entrypoint-initdb.d/ initialization, and docker-compose.yml also
-- passes `-c max_connections=100` directly to the server startup command so the setting
-- applies even when reusing an existing pgdata volume).
ALTER SYSTEM SET max_connections = 100;


