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

read -r -d '' REMOTE_SCRIPT << 'EOF' || true
set -euo pipefail

AWS_REGION="__AWS_REGION__"
ECR_REGISTRY="__ECR_REGISTRY__"
FULL_IMAGE="__FULL_IMAGE__"
SSM_CONFIG_PATH="__SSM_CONFIG_PATH__"

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

# 3. Fetch runtime secrets from AWS SSM Parameter Store into a secure tmpfs (/dev/shm) file.
#    - We bind-mount this tmpfs file read-only into the container (-v .../app.env:ro)
#      and source it via the container entrypoint instead of passing --env-file,
#      preventing Docker from persisting plaintext secrets onto the EBS root disk
#      under /var/lib/docker/containers/<id>/config.v2.json.
#    - We also install a lightweight boot-time systemd unit (Before=docker.service)
#      so if the EC2 host reboots, /dev/shm/api-*.env is repopulated from SSM
#      before Docker restarts the container (preventing Docker from creating an
#      empty directory at the missing tmpfs bind-mount path).
ENV_FILE="/dev/shm/api-${CANDIDATE_SLOT}.env"
OLD_ENV_FILE="/dev/shm/api-${ACTIVE_SLOT}.env"
umask 077
rm -rf "${ENV_FILE}"

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

echo "${SSM_JSON}" | jq -r '.Parameters[] | "\(.Name | split("/") | last)=\(.Value | @sh)"' > "${ENV_FILE}"
chmod 0400 "${ENV_FILE}"
chown 1000:1000 "${ENV_FILE}" || true

# Ensure boot-time systemd unit exists to repopulate /dev/shm/api-*.env before docker.service on EC2 reboot
cat > /usr/local/bin/hydrate-api-shm-secrets.sh <<BOOT_EOF
#!/usr/bin/env bash
set -euo pipefail
umask 077
for slot in blue green; do
  rm -rf "/dev/shm/api-\${slot}.env"
  aws ssm get-parameters-by-path --region "${AWS_REGION}" --path "${SSM_CONFIG_PATH}" --recursive --with-decryption --output json \
    | jq -r '.Parameters[] | "\(.Name | split("/") | last)=\(.Value | @sh)"' > "/dev/shm/api-\${slot}.env"
  chmod 0400 "/dev/shm/api-\${slot}.env"
  chown 1000:1000 "/dev/shm/api-\${slot}.env" || true
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

# 4. Run backward-compatible (expand-only) DB migrations if present before starting candidate
docker run --rm \
  -v "${ENV_FILE}:/run/secrets/app.env:ro" \
  --entrypoint /bin/sh \
  "${FULL_IMAGE}" \
  -c 'set -a && . /run/secrets/app.env && set +a && npm run migrate:up --if-present'

# 5. Start candidate container on the inactive port (sourcing secrets from in-memory tmpfs mount into process.env)
docker rm -f "api-${CANDIDATE_SLOT}" >/dev/null 2>&1 || true
docker run -d \
  --name "api-${CANDIDATE_SLOT}" \
  --restart unless-stopped \
  --init \
  -v "${ENV_FILE}:/run/secrets/app.env:ro" \
  -e PORT=3000 \
  -p "127.0.0.1:${CANDIDATE_PORT}:3000" \
  --entrypoint /bin/sh \
  "${FULL_IMAGE}" \
  -c 'set -a && . /run/secrets/app.env && set +a && exec node src/index.js'

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

# 6. Atomically switch local NGINX upstream to candidate port and reload
cat > /etc/nginx/conf.d/api-upstream.conf <<NGINX_EOF
upstream api_backend {
    server 127.0.0.1:${CANDIDATE_PORT};
    keepalive 32;
}
NGINX_EOF

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

# Substitute runtime variables into the remote payload
REMOTE_SCRIPT="${REMOTE_SCRIPT//__AWS_REGION__/${AWS_REGION}}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__ECR_REGISTRY__/${ECR_REGISTRY}}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__FULL_IMAGE__/${FULL_IMAGE}}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__SSM_CONFIG_PATH__/${SSM_CONFIG_PATH}}"

# Dispatch command via AWS SSM Run Command (1 instance at a time for rolling safety)
COMMAND_ID=$(aws ssm send-command \
  --region "${AWS_REGION}" \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Role,Values=${TARGET_TAG_VALUE}" \
  --max-concurrency "1" \
  --max-errors "0" \
  --comment "Deploy ${FULL_IMAGE}" \
  --parameters "$(jq -n --arg script "${REMOTE_SCRIPT}" '{commands: [$script]}')" \
  --query "Command.CommandId" \
  --output text)

echo "Dispatched SSM Command ID: ${COMMAND_ID}. Waiting for execution to finish..."

# Poll command status until completion (and verify TargetCount > 0 to prevent silent 0-instance success)
for attempt in $(seq 1 60); do
  read -r STATUS TARGET_COUNT COMPLETED_COUNT <<< "$(aws ssm list-commands \
    --region "${AWS_REGION}" \
    --command-id "${COMMAND_ID}" \
    --query "Commands[0].[Status,TargetCount,CompletedCount]" \
    --output text)"

  echo "[Attempt ${attempt}/60] SSM Command Status: ${STATUS} (Targets: ${COMPLETED_COUNT:-0}/${TARGET_COUNT:-0})"

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
  sleep 5
done

echo "ERROR: Timed out waiting for SSM Command ${COMMAND_ID}."
exit 1

