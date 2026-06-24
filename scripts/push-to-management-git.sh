#!/usr/bin/env bash
# =============================================================================
# push-to-management-git.sh
# -----------------------------------------------------------------------------
# Push the nkp-etcd-maintenance bootstrap manifests (catalog GitRepository,
# ClusterApp, AppDeployment) into the in-cluster management Git repo served by
# the NKP git-operator. After the commit is reconciled by Flux they are owned
# by the management repo, so the Kommander reconciler will NOT remove them and
# they survive snapshot/restore (anything kubectl-applied is volatile).
#
# Equivalent to the (non-existent) "nkp experimental gitops" command. Modeled
# on kommander's own test harness: tests/kuttl-kommander-operator/install/
# manifests/07_push_repo_to_git_server.sh
#
# Requirements:
#   - KUBECONFIG points at the NKP management cluster
#   - kubectl, git available locally
#   - Run from anywhere; the script resolves paths from its own location.
#
# What it does:
#   1.  Reads the management GitClaim path + credentials + CA from the cluster.
#   2.  Port-forwards svc/git-operator-git in the git-operator-system namespace.
#   3.  Clones the management repo over HTTPS (with the right CA pinned).
#   4.  Drops the bootstrap manifests under
#         clusters/kommander_<MGMT_CLUSTER>/custom/nkp-etcd-maintenance/
#       (a path the kommander reconciler does not own, so authoring there
#       is idempotent).
#   5.  Commits + pushes to main.
#   6.  kubectl-applies a "bootstrap" Flux Kustomization (named
#       <SUBDIR_NAME>-bootstrap, NOT <SUBDIR_NAME>) in `kommander-flux` that
#       points the cluster's existing flux instance at the new path. The
#       suffix is critical because Kommander's appmanagement controller
#       auto-generates a Kustomization named exactly <appdeployment-name>;
#       reusing that name causes a strategic-merge clobber on every apply.
#       prune: false so the bootstrap Kustomization only ever adds objects.
# =============================================================================

set -euo pipefail

# ---- inputs -----------------------------------------------------------------

: "${KUBECONFIG:?Set KUBECONFIG to the NKP management cluster}"
export KUBECONFIG

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-${REPO_ROOT}/bootstrap}"

# Subdirectory inside the management repo where we drop the manifests.
# Anything under clusters/kommander_<MGMT>/ is reconciled by the top-level
# Flux Kustomization. We pick a subfolder ("custom/...") that kommander
# does not author so re-runs are idempotent.
SUBDIR_NAME="${SUBDIR_NAME:-nkp-etcd-maintenance}"

COMMIT_MSG="${COMMIT_MSG:-add ${SUBDIR_NAME} virtual catalog}"
GIT_USER_NAME="${GIT_USER_NAME:-$(git config --get user.name 2>/dev/null || echo nkp-operator)}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-$(git config --get user.email 2>/dev/null || echo nkp-operator@nutanix.local)}"

# ---- discover the management cluster name ----------------------------------
#
# The right CRD on current NKP builds (>=2.18) is
#   kommanderclusters.kommander.mesosphere.io/v1beta1
# and the management cluster is the one carrying the "host" label.
# We also fall back to the older `apps.kommander.d2iq.io` API group and to
# the NKPCluster CR if the kommandercluster is not yet present.

if [[ -z "${MGMT_CLUSTER:-}" ]]; then
  for kind in \
      kommanderclusters.kommander.mesosphere.io \
      kommanderclusters.kommander.d2iq.io \
      nkpclusters.clusters.nkp.nutanix.com; do
    MGMT_CLUSTER="$(kubectl get "${kind}" -A \
      -l "kommander.d2iq.io/host=true" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${MGMT_CLUSTER}" ]] && break
  done
fi

if [[ -z "${MGMT_CLUSTER:-}" ]]; then
  echo "ERROR: could not auto-detect the management cluster name." >&2
  echo "       Tried kommanderclusters (mesosphere.io, d2iq.io) and " >&2
  echo "       nkpclusters with label 'kommander.d2iq.io/host=true'." >&2
  echo "Set MGMT_CLUSTER=<name> and re-run, e.g.:" >&2
  echo "  MGMT_CLUSTER=nkp-harsh-test-2 $0" >&2
  exit 1
fi
echo "[info] management cluster: ${MGMT_CLUSTER}"

# ---- discover the git-operator service ---------------------------------------

GIT_NS="${GIT_NS:-git-operator-system}"
GIT_SVC="${GIT_SVC:-git-operator-git}"

if ! kubectl -n "${GIT_NS}" get svc "${GIT_SVC}" >/dev/null 2>&1; then
  echo "ERROR: service ${GIT_SVC} not found in namespace ${GIT_NS}." >&2
  echo "On older NKP this used Gitea; check svc/kommander-git-server in" >&2
  echo "namespace 'kommander' and override with GIT_NS / GIT_SVC." >&2
  exit 1
fi

GIT_OPERATOR_HOSTPORT="${GIT_SVC}.${GIT_NS}:8443"

# ---- read GitClaim + credentials -------------------------------------------

GITCLAIM_NS="${GITCLAIM_NS:-kommander}"
GITCLAIM_NAME="${GITCLAIM_NAME:-kommander}"

REPO_PATH="$(kubectl -n "${GITCLAIM_NS}" get gitclaim "${GITCLAIM_NAME}" \
  -o jsonpath='{.status.path}')"
if [[ -z "${REPO_PATH}" ]]; then
  echo "ERROR: gitclaim ${GITCLAIM_NS}/${GITCLAIM_NAME} has no .status.path." >&2
  echo "Wait until the GitClaim is Ready and re-run." >&2
  exit 1
fi
echo "[info] management repo path: ${REPO_PATH}"

# Credentials are stored in two possible places depending on NKP version:
#   - newer: kommander-flux/kommander-git-credentials
#   - older: secret name on gitclaimusers/kommander -> .status.secretName
SECRET_NS="kommander-flux"
SECRET_NAME="kommander-git-credentials"
if ! kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" >/dev/null 2>&1; then
  SECRET_NS="${GITCLAIM_NS}"
  SECRET_NAME="$(kubectl -n "${GITCLAIM_NS}" get gitclaimuser kommander \
    -o jsonpath='{.status.secretName}' 2>/dev/null || true)"
fi
if [[ -z "${SECRET_NAME}" ]] \
  || ! kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" >/dev/null 2>&1; then
  echo "ERROR: could not locate management git credentials secret." >&2
  echo "Tried kommander-flux/kommander-git-credentials and " >&2
  echo "${GITCLAIM_NS}/<gitclaimuser kommander>.status.secretName." >&2
  exit 1
fi
echo "[info] git credentials secret: ${SECRET_NS}/${SECRET_NAME}"

GIT_USERNAME="$(kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" \
  -o jsonpath='{.data.username}' | base64 -d)"
GIT_PASSWORD="$(kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" \
  -o jsonpath='{.data.password}' | base64 -d)"

CA_FILE="$(mktemp)"
# Newer secret uses ca.crt, older one used caFile. Try both.
if ! kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "${CA_FILE}" \
  || [[ ! -s "${CA_FILE}" ]]; then
  kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" \
    -o jsonpath='{.data.caFile}' | base64 -d > "${CA_FILE}"
fi
if [[ ! -s "${CA_FILE}" ]]; then
  # Last resort: cert-manager kommander-ca (used by the install-time test).
  kubectl -n cert-manager get secret kommander-ca \
    -o template='{{ index .data "ca.crt" | base64decode }}' > "${CA_FILE}"
fi
[[ -s "${CA_FILE}" ]] || { echo "ERROR: empty CA bundle." >&2; exit 1; }

# ---- port-forward git-operator-git -----------------------------------------

PF_LOG="$(mktemp)"
kubectl -n "${GIT_NS}" port-forward --pod-running-timeout=1s \
  "svc/${GIT_SVC}" 8443:https >"${PF_LOG}" 2>&1 &
PF_PID=$!

cleanup() {
  kill "${PF_PID}" 2>/dev/null || true
  rm -f "${CA_FILE}" "${PF_LOG}"
  [[ -n "${WORK_DIR:-}" ]] && rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# Wait for "Forwarding from" to appear, max 15s.
for _ in $(seq 1 30); do
  grep -q 'Forwarding from' "${PF_LOG}" && break
  sleep 0.5
done
grep -q 'Forwarding from' "${PF_LOG}" || {
  echo "ERROR: port-forward did not establish:" >&2
  cat "${PF_LOG}" >&2
  exit 1
}

# ---- clone, modify, push ---------------------------------------------------

WORK_DIR="$(mktemp -d)"
cd "${WORK_DIR}"

export GIT_TERMINAL_PROMPT=0
export GIT_SSL_CAINFO="${CA_FILE}"

REPO_URL="https://${GIT_USERNAME}:${GIT_PASSWORD}@${GIT_OPERATOR_HOSTPORT}${REPO_PATH}"

git -c "http.curloptResolve=${GIT_OPERATOR_HOSTPORT}:127.0.0.1" \
    clone "${REPO_URL}" repo

cd repo
git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"
git config commit.gpgsign false

DEST_REL="clusters/kommander_${MGMT_CLUSTER}/custom/${SUBDIR_NAME}"
DEST="${DEST_REL}"
mkdir -p "${DEST}"

# Copy the bootstrap manifests. Only 00-namespace.yaml is excluded (it is a
# documentation-only stub; the workspace namespace already exists and is
# managed by Kommander).
#
# Note on the ClusterApp (02-clusterapp.yaml):
# Kommander's appmanagement controller actively garbage-collects cluster-
# scoped ClusterApps whose source it did not author itself, so the object
# disappears on its reconcile (~1 minute on this build). Shipping it through
# the bootstrap Flux Kustomization with `prune: false` re-creates it on the
# next Flux reconcile (also ~1 minute), so the catalog tile is present most
# of the time. This is a known NKP quirk for "virtual" catalogs that ship
# the ClusterApp from a non-management Git source; the production fix is to
# host the catalog from the NKP product catalog (OCIRepository) where the
# ClusterApp is generated by Kommander itself and never deleted.
SKIP_FILES_DEFAULT=$'00-namespace.yaml'
SKIP_FILES="${SKIP_FILES:-${SKIP_FILES_DEFAULT}}"

shopt -s nullglob
for f in "${BOOTSTRAP_DIR}"/*.yaml; do
  base="$(basename "${f}")"
  if grep -Fxq "${base}" <<<"${SKIP_FILES}"; then
    continue
  fi
  cp "${f}" "${DEST}/${base}"
done

# Remove any previously-shipped manifests that are now in the skip list,
# so re-runs converge correctly.
while IFS= read -r skipped; do
  [[ -z "${skipped}" ]] && continue
  if [[ -e "${DEST}/${skipped}" ]]; then
    git rm -f "${DEST}/${skipped}" >/dev/null
  fi
done <<<"${SKIP_FILES}"

# Plain kustomization that includes everything we just dropped. We rebuild
# this file from scratch every run, so a stale kustomization.yaml MUST be
# removed first -- otherwise the *.yaml glob below picks it up and lists it
# as a resource, which kustomize-build then tries to parse as a manifest
# and bails with "missing metadata.name".
rm -f "${DEST}/kustomization.yaml"

KUSTOM_RESOURCES=()
for f in "${DEST}"/*.yaml; do
  base="$(basename "${f}")"
  [[ "${base}" == "kustomization.yaml" ]] && continue
  KUSTOM_RESOURCES+=("${base}")
done

{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  for r in "${KUSTOM_RESOURCES[@]}"; do
    echo "- ${r}"
  done
} > "${DEST}/kustomization.yaml"

git add "${DEST}"

# Clean up an old (orphan) flux-kustomization YAML that earlier versions of
# this script wrote into git but nothing read.
ORPHAN_FLUX_KS="clusters/kommander_${MGMT_CLUSTER}/custom/${SUBDIR_NAME}-flux-kustomization.yaml"
if [[ -e "${ORPHAN_FLUX_KS}" ]]; then
  git rm -f "${ORPHAN_FLUX_KS}" >/dev/null
fi

if git diff --cached --quiet; then
  echo "[info] git already in sync; skipping commit/push"
else
  git commit -m "${COMMIT_MSG}"
  git -c "http.curloptResolve=${GIT_OPERATOR_HOSTPORT}:127.0.0.1" \
      push -u origin main
fi

# ---- apply the Flux Kustomization on the cluster ---------------------------
#
# IMPORTANT name collision warning:
#   Kommander's appmanagement controller auto-generates a Flux Kustomization
#   named "<appdeployment-name>" in the "kommander" namespace whenever an
#   AppDeployment exists. We MUST NOT reuse that name -- a `kubectl apply`
#   on it does a strategic merge that the controller may then revert,
#   transiently flipping spec.path and pruning the AppDeployment's
#   inventory. That's how we pruned the workspace GitRepository / ClusterApp
#   / AppDeployment in earlier runs.
#
# Mitigations:
#   - Use a "-bootstrap" suffix so the name is uniquely ours.
#   - prune: false so even a misconfiguration cannot delete cluster objects.
#   - Refuse to apply if a Kustomization with our name already exists and
#     is NOT labeled by us.

FLUX_KS_NAMESPACE="${FLUX_KS_NAMESPACE:-kommander-flux}"
FLUX_KS_NAME="${FLUX_KS_NAME:-${SUBDIR_NAME}-bootstrap}"
OWNER_LABEL_KEY="nkp.nutanix.com/managed-by"
OWNER_LABEL_VAL="push-to-management-git"

EXISTING_OWNER="$(kubectl -n "${FLUX_KS_NAMESPACE}" get kustomization "${FLUX_KS_NAME}" \
  -o jsonpath="{.metadata.labels.${OWNER_LABEL_KEY//./\\.}}" 2>/dev/null || true)"
if [[ -n "$(kubectl -n "${FLUX_KS_NAMESPACE}" get kustomization "${FLUX_KS_NAME}" \
  --ignore-not-found -o name 2>/dev/null)" \
  && "${EXISTING_OWNER}" != "${OWNER_LABEL_VAL}" ]]; then
  echo "ERROR: ${FLUX_KS_NAMESPACE}/Kustomization/${FLUX_KS_NAME} already exists" >&2
  echo "       and is NOT labeled ${OWNER_LABEL_KEY}=${OWNER_LABEL_VAL}." >&2
  echo "       Refusing to overwrite. Override the name with FLUX_KS_NAME=." >&2
  exit 1
fi

kubectl apply -f - <<EOF
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${FLUX_KS_NAME}
  namespace: ${FLUX_KS_NAMESPACE}
  labels:
    ${OWNER_LABEL_KEY}: ${OWNER_LABEL_VAL}
spec:
  interval: 1m
  path: ./${DEST_REL}
  # prune: false on purpose -- this Kustomization only ever ADDs the
  # bootstrap objects (GitRepository, ClusterApp, AppDeployment); it must
  # never delete them, and must never touch unrelated cluster state.
  prune: false
  retryInterval: 30s
  sourceRef:
    kind: GitRepository
    name: management
    namespace: kommander-flux
  timeout: 2m
EOF

# Force an immediate reconcile of the management GitRepository so Flux fetches
# the commit we just pushed without waiting for the poll interval.
kubectl -n kommander-flux annotate --overwrite gitrepository management \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null || true
# Same for the bootstrap Kustomization (in case it already existed and is
# tracking an older revision).
kubectl -n "${FLUX_KS_NAMESPACE}" annotate --overwrite \
  kustomization "${FLUX_KS_NAME}" \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null || true

echo
echo "[done] pushed ${SUBDIR_NAME} to management git and applied bootstrap Kustomization."
echo "       Verify with:"
echo "         kubectl -n ${FLUX_KS_NAMESPACE} get kustomization ${FLUX_KS_NAME} -w"
echo "         kubectl -n kommander-default-workspace get gitrepository,appdeployment"
echo "         kubectl get clusterapp ${SUBDIR_NAME}-0.3.0"
