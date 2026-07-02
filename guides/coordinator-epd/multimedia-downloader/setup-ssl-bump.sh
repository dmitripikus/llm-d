#!/usr/bin/env bash
# Deploy the SSL-Bump multimedia downloader (HTTPS caching) and wire its CA
# into the coordinator.
#
# Steps:
#   1. Clone the mm_service-guides branch into a temp dir.
#   2. Run the helper that builds/applies the SSL-Bump Squid + CA secret.
#   3. Apply the coordinator CA patch.
#   4. Restart the coordinator so it trusts the Squid CA.
#
# Usage:
#   ./setup-ssl-bump.sh
#
# Environment:
#   NAMESPACE   Target namespace (default: current kubectl context ns, else llm-d-epd)
#   REPO_URL    Source repo (default: https://github.com/revit13/llm-d.git)
#   BRANCH      Source branch (default: mm_service-guides)
#   CLONE_DIR   Where to clone (default: /tmp/llm-d)

set -euo pipefail

# Default to the current kubectl context's namespace, falling back to llm-d-epd.
NAMESPACE="${NAMESPACE:-$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)}"
NAMESPACE="${NAMESPACE:-llm-d-epd}"
REPO_URL="${REPO_URL:-https://github.com/revit13/llm-d.git}"
BRANCH="${BRANCH:-mm_service-guides}"
CLONE_DIR="${CLONE_DIR:-/tmp/llm-d}"
COORDINATOR_DEPLOYMENT="llm-d-coordinator"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Clone (or refresh) the branch.
if [[ -d "${CLONE_DIR}/.git" ]]; then
  echo "Reusing existing clone at ${CLONE_DIR}, fetching ${BRANCH}..."
  git -C "${CLONE_DIR}" fetch origin "${BRANCH}"
  git -C "${CLONE_DIR}" checkout "${BRANCH}"
  git -C "${CLONE_DIR}" pull --ff-only origin "${BRANCH}"
else
  echo "Cloning ${REPO_URL} (${BRANCH}) into ${CLONE_DIR}..."
  git clone -b "${BRANCH}" "${REPO_URL}" "${CLONE_DIR}"
fi

# 2. Deploy the SSL-Bump Squid via the helper script.
echo "Deploying SSL-Bump Squid..."
"${CLONE_DIR}/helpers/multimedia-downloader/implementations/squid/test/test-squid.sh" \
  --mode ssl-bump --openshift --skip-cleanup

# 3. Trust the Squid CA in the coordinator. This is a strategic merge patch
# (partial spec), so it must be applied with `kubectl patch`, not `kubectl apply`.
echo "Applying coordinator CA patch..."
kubectl patch "deployment/${COORDINATOR_DEPLOYMENT}" -n "${NAMESPACE}" \
  --type=strategic --patch-file "${SCRIPT_DIR}/patch-coordinator-ca.yaml"

# 4. Restart the coordinator so it picks up the CA.
echo "Restarting ${COORDINATOR_DEPLOYMENT}..."
kubectl rollout restart "deployment/${COORDINATOR_DEPLOYMENT}" -n "${NAMESPACE}"
kubectl rollout status "deployment/${COORDINATOR_DEPLOYMENT}" -n "${NAMESPACE}"

echo "SSL-Bump multimedia downloader setup complete."
