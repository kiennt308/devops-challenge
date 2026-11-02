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
  if [[ ! "${ROLLBACK_SHA}" =~ ^[a-fA-F0-9]{7,40}$ ]]; then
    echo "ERROR: Invalid ROLLBACK_SHA '${ROLLBACK_SHA}'. Expected 7-40 hex characters."
    exit 1
  fi
  # Resolve prefix (supports both 7-char short SHA and 40-char full SHA) against the S3 release archive
  # and verify that index.html actually exists before touching the live bucket.
  MATCHED_PREFIX=$(aws s3api list-objects-v2 \
    --bucket "${ARCHIVE_BUCKET}" \
    --prefix "${ROLLBACK_SHA}" \
    --delimiter "/" \
    --query "CommonPrefixes[0].Prefix" \
    --output text 2>/dev/null || echo "None")

  if [ -z "${MATCHED_PREFIX}" ] || [ "${MATCHED_PREFIX}" = "None" ]; then
    echo "ERROR: No archived release matching '${ROLLBACK_SHA}' found in s3://${ARCHIVE_BUCKET}/! Aborting rollback."
    exit 1
  fi

  ACTIVE_SHA="${MATCHED_PREFIX%/}"
  SOURCE_URI="s3://${ARCHIVE_BUCKET}/${ACTIVE_SHA}"

  if ! aws s3api head-object --bucket "${ARCHIVE_BUCKET}" --key "${ACTIVE_SHA}/index.html" >/dev/null 2>&1; then
    echo "ERROR: Archive ${SOURCE_URI}/index.html is missing or incomplete! Aborting rollback."
    exit 1
  fi

  echo "Rolling back S3 bucket s3://${S3_BUCKET} directly from verified S3 archive ${SOURCE_URI}/ (S3-to-S3 copy)..."
  mkdir -p "${DIST_DIR}"
else
  ACTIVE_SHA="${RELEASE_SHA}"
  SOURCE_URI="${DIST_DIR}"
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
if [ -n "${ROLLBACK_SHA}" ] || [ -d "${DIST_DIR}/assets" ]; then
  aws s3 sync "${SOURCE_URI}/assets/" "s3://${S3_BUCKET}/assets/" \
    --cache-control "public, max-age=31536000, immutable" \
    --only-show-errors
fi

echo "Phase 1b: Uploading non-fingerprinted root static files (favicon, manifest, robots.txt) with short TTL..."
# On rollback (or standard sync of root-level non-hashed files), include --delete
# with exclusions for assets/* and entrypoints so any stale root-level file introduced
# by a bad release is cleanly removed without touching fingerprinted assets/*.
aws s3 sync "${SOURCE_URI}/" "s3://${S3_BUCKET}/" \
  --delete \
  --exclude "assets/*" \
  --exclude "index.html" \
  --exclude "config.json" \
  --exclude "service-worker.js" \
  --cache-control "public, max-age=3600, must-revalidate" \
  --only-show-errors

echo "Phase 2: Uploading entrypoints (index.html, config.json) with no-cache headers..."
aws s3 cp "${DIST_DIR}/config.json" "s3://${S3_BUCKET}/config.json" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "application/json; charset=utf-8"

for entry in index.html service-worker.js; do
  CONTENT_TYPE="text/html; charset=utf-8"
  [[ "${entry}" == *.js ]] && CONTENT_TYPE="application/javascript; charset=utf-8"

  if [ -n "${ROLLBACK_SHA}" ]; then
    aws s3 cp "${SOURCE_URI}/${entry}" "s3://${S3_BUCKET}/${entry}" \
      --cache-control "no-cache, no-store, must-revalidate" \
      --content-type "${CONTENT_TYPE}" 2>/dev/null || true
  elif [ -f "${DIST_DIR}/${entry}" ]; then
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

if [ -z "${ROLLBACK_SHA}" ]; then
  echo "Phase 4: Pruning obsolete hashed assets older than 7 days that are not in the active release..."
  # Why not use a blind 30-day S3 Lifecycle Expiration on the live bucket?
  # Because unchanged hashed chunks (e.g. vendor.js or fonts) keep their original CreationDate
  # across builds and would be deleted by S3 Lifecycle while still referenced by index.html!
  # Instead, we only prune s3://${S3_BUCKET}/assets/* objects that are BOTH absent from the
  # current ${DIST_DIR}/assets/ bundle AND older than 7 days, using batch delete-objects
  # (up to 1,000 keys per API call) instead of slow per-file `aws s3 rm` loops.
  CUTOFF_ISO=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ")
  STALE_KEYS_JSON=$(aws s3api list-objects-v2 \
    --bucket "${S3_BUCKET}" \
    --prefix "assets/" \
    --query "Contents[?LastModified<='${CUTOFF_ISO}'].Key" \
    --output json)

  # Filter against local DIST_DIR manifest and execute batch delete in chunks of 500
  # (AWS s3api delete-objects accepts up to 1,000 objects per API call)
  STALE_ARRAY=()
  while IFS= read -r key; do
    if [ -n "${key}" ] && [ ! -f "${DIST_DIR}/${key}" ]; then
      STALE_ARRAY+=("${key}")
    fi
  done < <(echo "${STALE_KEYS_JSON}" | jq -r '.[]? // empty')

  TOTAL_STALE="${#STALE_ARRAY[@]}"
  if [ "${TOTAL_STALE}" -gt 0 ]; then
    echo "Batch-pruning ${TOTAL_STALE} obsolete asset(s) from s3://${S3_BUCKET}/assets/..."
    for (( offset=0; offset<TOTAL_STALE; offset+=500 )); do
      CHUNK=("${STALE_ARRAY[@]:offset:500}")
      printf '%s\n' "${CHUNK[@]}" | jq -R '{Key: .}' | jq -s -c '{Objects: ., Quiet: true}' | \
        aws s3api delete-objects --bucket "${S3_BUCKET}" --delete file:///dev/stdin >/dev/null
    done
  fi
fi

echo "Frontend SPA release ${ACTIVE_SHA} is live!"

