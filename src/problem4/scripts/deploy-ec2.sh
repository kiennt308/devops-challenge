#!/usr/bin/env bash
# ==============================================================================
# Zero-Downtime Blue/Green Container Rollout on EC2 via AWS SSM Run Command
# ==============================================================================
# This script is invoked by GitHub Actions and executes a remote shell script on
# target EC2 instances matching tag:Role=${TARGET_TAG_VALUE} via AWS Systems
# Manager (SSM) Run Command. No inbound SSH ports (22) or bastion hosts are needed.
#
# On each EC2 instance, local NGINX proxies traffic to either port 3001 (blue)
# or port 3002 (green). The remote command:
#   1. Fetches runtime configuration from AWS SSM Parameter Store
#   2. Pulls the new immutable ECR image (${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG})
#   3. Starts the candidate container on the inactive port (3001 or 3002)
#   4. Polls http://127.0.0.1:<candidate_port>/status until healthy
#   5. Reloads NGINX upstream to cut traffic over to the candidate container
#   6. Gracefully drains and stops the old container, or rolls back if health check fails.
# ==============================================================================

set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${ECR_REGISTRY:?ECR_REGISTRY is required}"
: "${ECR_REPOSITORY:?ECR_REPOSITORY is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"
: "${TARGET_TAG_VALUE:?TARGET_TAG_VALUE is required}"
: "${SSM_CONFIG_PATH:?SSM_CONFIG_PATH is required}"

FULL_IMAGE="${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"
echo "Starting SSM zero-downtime rollout of ${FULL_IMAGE} to EC2 instances tagged Role=${TARGET_TAG_VALUE}..."

read -r -d '' REMOTE_BODY << 'EOF' || true
set -euo pipefail

# 1. Determine active vs candidate slot using NGINX upstream config as the
#    primary source of truth (avoids killing the live slot if both containers
#    are running after a previously interrupted drain).
if grep -q '127\.0\.0\.1:3002' /etc/nginx/conf.d/api-upstream.conf 2>/dev/null; then
  ACTIVE_SLOT="green"
  ACTIVE_PORT=3002
  CANDIDATE_SLOT="blue"
  CANDIDATE_PORT=3001
elif grep -q '127\.0\.0\.1:3001' /etc/nginx/conf.d/api-upstream.conf 2>/dev/null; then
  ACTIVE_SLOT="blue"
  ACTIVE_PORT=3001
  CANDIDATE_SLOT="green"
  CANDIDATE_PORT=3002
elif docker ps --format '{{.Names}}' | grep -q '^api-blue$'; then
  ACTIVE_SLOT="blue"
  ACTIVE_PORT=3001
  CANDIDATE_SLOT="green"
  CANDIDATE_PORT=3002
else
  ACTIVE_SLOT="green"
  ACTIVE_PORT=3002
  CANDIDATE_SLOT="blue"
  CANDIDATE_PORT=3001
fi

echo "[SSM] Active slot: ${ACTIVE_SLOT} (${ACTIVE_PORT}) -> Deploying candidate: ${CANDIDATE_SLOT} (${CANDIDATE_PORT})"

# 2. Authenticate to ECR using the EC2 Instance Profile
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker pull "${FULL_IMAGE}"

# 3. Fetch runtime secrets from AWS SSM Parameter Store into a secure tmpfs (/dev/shm) JSON file.
#    - Instead of passing --env-file (which causes Docker to persist plaintext secrets onto
#      the EBS root disk in /var/lib/docker/containers/<id>/config.v2.json) or relying on
#      `/bin/sh` + `jq @sh` (which fails on shell-less Distroless images and can break on
#      multiline/special-character secret values across dash/ash), we serialize a strict
#      JSON key-value map (/dev/shm/api-<slot>.secrets.json) and load it directly into
#      Node.js `process.env` via a tiny read-only preload script (`NODE_OPTIONS="--require /run/secrets/preload.js"`).
#    - This works identically on both Alpine/Debian and shell-less Distroless Node.js images,
#      handles arbitrary special/multiline characters safely via `JSON.parse`, and keeps
#      secrets strictly in RAM (`tmpfs`).
ENV_FILE="/dev/shm/api-${CANDIDATE_SLOT}.secrets.json"
OLD_ENV_FILE="/dev/shm/api-${ACTIVE_SLOT}.secrets.json"
PRELOAD_JS="/dev/shm/preload-secrets.js"
umask 077
rm -rf "${ENV_FILE}"

cat > "${PRELOAD_JS}" <<'PRELOAD_EOF'
const fs = require("fs");
const secretPath = "/run/secrets/app.secrets.json";
if (fs.existsSync(secretPath)) {
  const secrets = JSON.parse(fs.readFileSync(secretPath, "utf8"));
  for (const [k, v] of Object.entries(secrets)) {
    if (process.env[k] === undefined) process.env[k] = String(v);
  }
}
PRELOAD_EOF
chmod 0444 "${PRELOAD_JS}"

SSM_JSON=$(aws ssm get-parameters-by-path \
  --region "${AWS_REGION}" \
  --path "${SSM_CONFIG_PATH}" \
  --recursive \
  --with-decryption \
  --output json)

PARAM_COUNT=$(echo "${SSM_JSON}" | jq '[.Parameters[]] | length')
if [ "${PARAM_COUNT}" -eq 0 ]; then
  echo "[SSM] ERROR: No parameters found at SSM path ${SSM_CONFIG_PATH}! Aborting deployment."
  exit 1
fi

echo "${SSM_JSON}" | jq 'reduce .Parameters[] as $p ({}; .[($p.Name | split("/") | last)] = $p.Value)' > "${ENV_FILE}"

# Inspect image metadata directly (without spawning `/usr/bin/id`, which does not exist in Distroless images)
IMAGE_USER=$(docker inspect --format='{{.Config.User}}' "${FULL_IMAGE}" 2>/dev/null || echo "")
case "${IMAGE_USER}" in
  ""|root|0|0:0)
    CONTAINER_UID=0; CONTAINER_GID=0 ;;
  node|node:node)
    CONTAINER_UID=1000; CONTAINER_GID=1000 ;;
  nonroot|nonroot:nonroot)
    CONTAINER_UID=65532; CONTAINER_GID=65532 ;;
  *:*)
    CONTAINER_UID="${IMAGE_USER%%:*}"; CONTAINER_GID="${IMAGE_USER##*:}" ;;
  *)
    if [[ "${IMAGE_USER}" =~ ^[0-9]+$ ]]; then
      CONTAINER_UID="${IMAGE_USER}"; CONTAINER_GID="${IMAGE_USER}"
    else
      CONTAINER_UID=1000; CONTAINER_GID=1000
    fi
    ;;
esac
chmod 0400 "${ENV_FILE}"
chown "${CONTAINER_UID}:${CONTAINER_GID}" "${ENV_FILE}" 2>/dev/null || chmod 0444 "${ENV_FILE}"

# Ensure boot-time systemd unit exists to repopulate /dev/shm/api-*.secrets.json before docker.service on EC2 reboot
cat > /usr/local/bin/hydrate-api-shm-secrets.sh <<BOOT_EOF
#!/usr/bin/env bash
set -euo pipefail
umask 077
cat > "${PRELOAD_JS}" <<'INNER_EOF'
const fs = require("fs");
const secretPath = "/run/secrets/app.secrets.json";
if (fs.existsSync(secretPath)) {
  const secrets = JSON.parse(fs.readFileSync(secretPath, "utf8"));
  for (const [k, v] of Object.entries(secrets)) {
    if (process.env[k] === undefined) process.env[k] = String(v);
  }
}
INNER_EOF
chmod 0444 "${PRELOAD_JS}"
for slot in blue green; do
  rm -rf "/dev/shm/api-\${slot}.secrets.json"
  aws ssm get-parameters-by-path --region "${AWS_REGION}" --path "${SSM_CONFIG_PATH}" --recursive --with-decryption --output json \
    | jq 'reduce .Parameters[] as \$p ({}; .[(\$p.Name | split("/") | last)] = \$p.Value)' > "/dev/shm/api-\${slot}.secrets.json"
  chmod 0400 "/dev/shm/api-\${slot}.secrets.json"
  chown "${CONTAINER_UID}:${CONTAINER_GID}" "/dev/shm/api-\${slot}.secrets.json" 2>/dev/null || chmod 0444 "/dev/shm/api-\${slot}.secrets.json"
done
BOOT_EOF
chmod 0700 /usr/local/bin/hydrate-api-shm-secrets.sh

cat > /etc/systemd/system/api-shm-secrets.service <<UNIT_EOF
[Unit]
Description=Hydrate in-memory /dev/shm API secrets from AWS SSM before Docker starts
DefaultDependencies=no
After=network-online.target amazon-ssm-agent.service
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hydrate-api-shm-secrets.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload && systemctl enable api-shm-secrets.service >/dev/null 2>&1 || true

# 4. Run backward-compatible (expand-only) DB migrations ONCE per release across the fleet.
#    Since SSM executes with --max-concurrency 1, the first EC2 instance runs migrate and
#    records ${FULL_IMAGE} in SSM Parameter Store so instances 2..N skip redundant migration runs.
#    Note: Uses `node` directly (e.g. `src/migrate.js`) if present so it works on both
#    standard Alpine/Debian images and shell-less Distroless images (which have `node` but no `npm`).
LAST_MIGRATED=$(aws ssm get-parameter --region "${AWS_REGION}" --name "${SSM_CONFIG_PATH}/_last_migrated_image" --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [ "${LAST_MIGRATED}" != "${FULL_IMAGE}" ]; then
  echo "[SSM] Running expand-only database migrations for ${FULL_IMAGE} (once per release)..."
  docker run --rm \
    -v "${ENV_FILE}:/run/secrets/app.secrets.json:ro" \
    -v "${PRELOAD_JS}:/run/secrets/preload.js:ro" \
    -e NODE_OPTIONS="--require /run/secrets/preload.js" \
    --entrypoint node \
    "${FULL_IMAGE}" \
    -e 'const fs=require("fs"),cp=require("child_process"); if(fs.existsSync("src/migrate.js")){require("./src/migrate.js");}else if(fs.existsSync("package.json")&& (JSON.parse(fs.readFileSync("package.json")).scripts||{})["migrate:up"]){cp.execSync("npm run migrate:up",{stdio:"inherit"});}'
  aws ssm put-parameter \
    --region "${AWS_REGION}" \
    --name "${SSM_CONFIG_PATH}/_last_migrated_image" \
    --value "${FULL_IMAGE}" \
    --type "String" \
    --overwrite >/dev/null 2>&1 || true
else
  echo "[SSM] Database migrations already applied for ${FULL_IMAGE}; skipping on this instance."
fi

# 5. Start candidate container on the inactive port, preserving the image's native
#    ENTRYPOINT/CMD directly (no `/bin/sh` wrapper required, full Distroless compatibility).
docker rm -f "api-${CANDIDATE_SLOT}" >/dev/null 2>&1 || true
docker run -d \
  --name "api-${CANDIDATE_SLOT}" \
  --restart unless-stopped \
  --init \
  -v "${ENV_FILE}:/run/secrets/app.secrets.json:ro" \
  -v "${PRELOAD_JS}:/run/secrets/preload.js:ro" \
  -e NODE_OPTIONS="--require /run/secrets/preload.js" \
  -e PORT=3000 \
  -p "127.0.0.1:${CANDIDATE_PORT}:3000" \
  "${FULL_IMAGE}"

# 5. Poll candidate health check (/status) before switching traffic
HEALTHY=0
for i in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${CANDIDATE_PORT}/status" >/dev/null 2>&1; then
    HEALTHY=1
    echo "[SSM] Candidate api-${CANDIDATE_SLOT} passed health check on attempt ${i}."
    break
  fi
  sleep 2
done

if [ "${HEALTHY}" -ne 1 ]; then
  echo "[SSM] ERROR: Candidate container failed health check! Capturing logs and aborting rollout..."
  docker logs --tail 50 "api-${CANDIDATE_SLOT}" || true
  docker rm -f "api-${CANDIDATE_SLOT}" || true
  rm -f "${ENV_FILE}"
  exit 1
fi

# 6. Atomically switch local NGINX upstream to candidate port, ensure reverse-proxy
#    server block exists (for Day-0 newly provisioned EC2 instances), and reload
cat > /etc/nginx/conf.d/api-upstream.conf <<NGINX_EOF
upstream api_backend {
    server 127.0.0.1:${CANDIDATE_PORT};
    keepalive 32;
}
NGINX_EOF

if [ ! -f /etc/nginx/conf.d/api-server.conf ]; then
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true
  cat > /etc/nginx/conf.d/api-server.conf <<'SERVER_EOF'
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }
}
SERVER_EOF
fi

nginx -t && systemctl reload nginx
echo "[SSM] Traffic cut over to api-${CANDIDATE_SLOT} on port ${CANDIDATE_PORT}."

# 7. Gracefully drain and stop the previous slot container, then wipe its tmpfs secret file
if docker ps --format '{{.Names}}' | grep -q "^api-${ACTIVE_SLOT}$"; then
  echo "[SSM] Draining previous container api-${ACTIVE_SLOT}..."
  docker stop --time 30 "api-${ACTIVE_SLOT}"
  docker rm "api-${ACTIVE_SLOT}"
fi
rm -f "${OLD_ENV_FILE}"

docker image prune -f >/dev/null 2>&1 || true
echo "[SSM] Deployment of ${FULL_IMAGE} completed successfully."
EOF

# Safely quote runtime variables with printf '%q' instead of string replacement
# so special characters (&, \, quotes) never break shell syntax on the target host
printf -v ENV_HEADER "AWS_REGION=%q\nECR_REGISTRY=%q\nFULL_IMAGE=%q\nSSM_CONFIG_PATH=%q\n" \
  "${AWS_REGION}" "${ECR_REGISTRY}" "${FULL_IMAGE}" "${SSM_CONFIG_PATH}"
REMOTE_SCRIPT="${ENV_HEADER}${REMOTE_BODY}"

# Dispatch command via AWS SSM Run Command:
#   - Uses --max-concurrency "${SSM_MAX_CONCURRENCY:-1}" (defaults to 1 instance at a time
#     for sequential rolling safety and fleet-once migration gating; configurable to "25%" for large fleets).
#   - Polling loop dynamically extends up to 180 attempts * 5s = 15 minutes (matching the
#     GitHub Actions job timeout) and adjusts dynamically once TARGET_COUNT is reported so
#     multi-instance production fleets (e.g. 8-15 EC2 instances) never hit a premature 5-minute timeout.
MAX_CONCURRENCY="${SSM_MAX_CONCURRENCY:-1}"
COMMAND_ID=$(aws ssm send-command \
  --region "${AWS_REGION}" \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Role,Values=${TARGET_TAG_VALUE}" \
  --max-concurrency "${MAX_CONCURRENCY}" \
  --max-errors "0" \
  --comment "Deploy ${FULL_IMAGE}" \
  --parameters "$(jq -n --arg script "${REMOTE_SCRIPT}" '{commands: [$script]}')" \
  --query "Command.CommandId" \
  --output text)

echo "Dispatched SSM Command ID: ${COMMAND_ID} (max-concurrency=${MAX_CONCURRENCY}). Waiting for execution to finish..."

MAX_ATTEMPTS="${SSM_POLL_MAX_ATTEMPTS:-180}"
attempt=1
while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
  read -r STATUS TARGET_COUNT COMPLETED_COUNT <<< "$(aws ssm list-commands \
    --region "${AWS_REGION}" \
    --command-id "${COMMAND_ID}" \
    --query "Commands[0].[Status,TargetCount,CompletedCount]" \
    --output text)"

  # Dynamically ensure at least 12 attempts (60s) per target instance when running sequentially
  if [ "${TARGET_COUNT:-0}" -gt 0 ]; then
    REQUIRED_ATTEMPTS=$(( TARGET_COUNT * 12 + 24 ))
    if [ "${REQUIRED_ATTEMPTS}" -gt "${MAX_ATTEMPTS}" ]; then
      MAX_ATTEMPTS="${REQUIRED_ATTEMPTS}"
    fi
  fi

  echo "[Attempt ${attempt}/${MAX_ATTEMPTS}] SSM Command Status: ${STATUS} (Targets: ${COMPLETED_COUNT:-0}/${TARGET_COUNT:-0})"

  if [ "${TARGET_COUNT:-0}" -eq 0 ] && [ "${STATUS}" != "Pending" ]; then
    echo "ERROR: SSM Command ${COMMAND_ID} matched 0 EC2 instances for tag Role=${TARGET_TAG_VALUE}!"
    exit 1
  fi

  case "${STATUS}" in
    Success)
      echo "EC2 deployment succeeded across all ${TARGET_COUNT} target instance(s)."
      exit 0
      ;;
    Failed|Cancelled|TimedOut|Cancelling)
      echo "ERROR: SSM deployment failed with status: ${STATUS}"
      aws ssm list-command-invocations \
        --region "${AWS_REGION}" \
        --command-id "${COMMAND_ID}" \
        --details \
        --query "CommandInvocations[*].[InstanceId,Status,CommandPlugins[0].Output]" \
        --output text
      exit 1
      ;;
  esac
  attempt=$(( attempt + 1 ))
  sleep 5
done

echo "ERROR: Timed out waiting for SSM Command ${COMMAND_ID}."
exit 1

