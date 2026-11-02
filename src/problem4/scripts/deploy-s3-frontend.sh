#!/usr/bin/env bash
# ==============================================================================
# Two-Phase Atomic S3 SPA Deployment & CloudFront Invalidation
# ==============================================================================
# Prevents white-screen/404 ChunkLoadError race conditions during SPA rollouts:
#   Phase 1: Upload fingerprinted static assets (assets/*) with immutable 1-year
#            Cache-Control WITHOUT deleting previous assets immediately, so active
#            users on the old index.html can still lazy-load chunks.
#   Phase 2: Generate runtime /config.json and upload index.html + config.json
#            with Cache-Control: no-cache, no-store, must-revalidate.
#   Phase 3: Archive the release under s3://<bucket>-releases/<sha>/ for instant
#            1-step rollback, then trigger CloudFront invalidation for /index.html
#            and /config.json.
# ==============================================================================

set -euo pipefail

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${CF_DISTRIBUTION_ID:?CF_DISTRIBUTION_ID is required}"
: "${API_BASE_URL:?API_BASE_URL is required}"
: "${RELEASE_SHA:?RELEASE_SHA is required}"

ROLLBACK_SHA="${ROLLBACK_SHA:-}"
DIST_DIR="${DIST_DIR:-./dist}"
ARCHIVE_BUCKET="${S3_BUCKET}-releases"

if [ -n "${ROLLBACK_SHA}" ]; then
  echo "Rolling back S3 bucket s3://${S3_BUCKET} to archived release ${ROLLBACK_SHA}..."
  mkdir -p "${DIST_DIR}"
  aws s3 sync "s3://${ARCHIVE_BUCKET}/${ROLLBACK_SHA}/" "${DIST_DIR}/" --exact-timestamps --only-show-errors
  ACTIVE_SHA="${ROLLBACK_SHA}"
else
  ACTIVE_SHA="${RELEASE_SHA}"
  echo "Archiving immutable release ${ACTIVE_SHA} to s3://${ARCHIVE_BUCKET}/${ACTIVE_SHA}/..."
  aws s3 sync "${DIST_DIR}/" "s3://${ARCHIVE_BUCKET}/${ACTIVE_SHA}/" --only-show-errors
fi

# Generate environment-specific runtime configuration (keeps compiled JS bundle immutable)
cat > "${DIST_DIR}/config.json" <<EOF
{
  "apiBaseUrl": "${API_BASE_URL}",
  "releaseSha": "${ACTIVE_SHA}",
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

echo "Phase 1a: Uploading fingerprinted assets (assets/*) with 1-year immutable caching..."
if [ -d "${DIST_DIR}/assets" ]; then
  aws s3 sync "${DIST_DIR}/assets/" "s3://${S3_BUCKET}/assets/" \
    --cache-control "public, max-age=31536000, immutable" \
    --only-show-errors
fi

echo "Phase 1b: Uploading non-fingerprinted root static files (favicon, manifest, robots.txt) with short TTL..."
aws s3 sync "${DIST_DIR}/" "s3://${S3_BUCKET}/" \
  --exclude "assets/*" \
  --exclude "index.html" \
  --exclude "config.json" \
  --exclude "service-worker.js" \
  --cache-control "public, max-age=3600, must-revalidate" \
  --only-show-errors

echo "Phase 2: Uploading entrypoints (index.html, config.json) with no-cache headers..."
for entry in index.html config.json service-worker.js; do
  if [ -f "${DIST_DIR}/${entry}" ]; then
    CONTENT_TYPE="text/html; charset=utf-8"
    [[ "${entry}" == *.json ]] && CONTENT_TYPE="application/json; charset=utf-8"
    [[ "${entry}" == *.js ]] && CONTENT_TYPE="application/javascript; charset=utf-8"

    aws s3 cp "${DIST_DIR}/${entry}" "s3://${S3_BUCKET}/${entry}" \
      --cache-control "no-cache, no-store, must-revalidate" \
      --content-type "${CONTENT_TYPE}"
  fi
done

echo "Phase 3: Invalidating CloudFront edge cache for entrypoints..."
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "${CF_DISTRIBUTION_ID}" \
  --paths "/index.html" "/config.json" "/service-worker.js" \
  --query "Invalidation.Id" \
  --output text)

echo "Waiting for CloudFront Invalidation ${INVALIDATION_ID} to complete..."
aws cloudfront wait invalidation-completed \
  --distribution-id "${CF_DISTRIBUTION_ID}" \
  --id "${INVALIDATION_ID}"

echo "Phase 4: Pruning obsolete hashed assets older than 7 days that are not in the active release..."
# Why not use a blind 30-day S3 Lifecycle Expiration on the live bucket?
# Because unchanged hashed chunks (e.g. vendor.js or fonts) keep their original CreationDate
# across builds and would be deleted by S3 Lifecycle while still referenced by index.html!
# Instead, we only prune s3://${S3_BUCKET}/assets/* objects that are BOTH absent from the
# current ${DIST_DIR}/assets/ bundle AND older than 7 days (preserving active + recent chunks).
CUTOFF_ISO=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ")
aws s3api list-objects-v2 \
  --bucket "${S3_BUCKET}" \
  --prefix "assets/" \
  --query "Contents[?LastModified<='${CUTOFF_ISO}'].Key" \
  --output text | tr '\t' '\n' | while read -r key; do
    if [ -n "${key}" ] && [ "${key}" != "None" ] && [ ! -f "${DIST_DIR}/${key}" ]; then
      echo "Pruning obsolete asset s3://${S3_BUCKET}/${key}..."
      aws s3 rm "s3://${S3_BUCKET}/${key}" --only-show-errors
    fi
  done

echo "Frontend SPA release ${ACTIVE_SHA} is live!"

