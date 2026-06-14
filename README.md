# nkp-virtual-catalog

A self-contained **test catalog** for NKP / Kommander that ships the
`nkp-etcd-maintenance` Helm chart end-to-end, without needing access to
the internal Nutanix Harbor registry or an external OCI chart repository.

The chart source files live in this same repo (`charts/nkp-etcd-maintenance/`)
and are pulled by Flux as a `GitRepository` source, so this catalog works on
any cluster that can reach the catalog's git URL.

## Layout

```
nkp-virtual-catalog/
├── README.md
├── applications/
│   └── nkp-etcd-maintenance/
│       ├── metadata.yaml               # top-level app metadata (dashboard tile)
│       └── 0.3.0/
│           ├── metadata.yaml           # per-version metadata
│           ├── kustomization.yaml      # entry kustomization
│           └── release/
│               ├── kustomization.yaml
│               ├── nkp-etcd-maintenance.yaml   # HelmRelease + chart GitRepository
│               └── cm.yaml                     # catalog-default values
├── charts/
│   └── nkp-etcd-maintenance/                   # full chart, embedded
└── bootstrap/
    ├── 00-namespace.yaml
    ├── 01-catalog-gitrepository.yaml           # Flux source for this repo
    ├── 02-clusterapp.yaml                      # Kommander catalog registration
    └── 03-appdeployment.yaml                   # (optional) install via kubectl
```

## How the parts fit together

```
        ┌──────────────────────────────────────────────────┐
        │ Operator pushes this repo to a Git URL Kommander │
        │ can reach (their fork, in-cluster git-operator,  │
        │ etc.).                                           │
        └─────────────────────────┬────────────────────────┘
                                  │
                                  ▼
        ┌──────────────────────────────────────────────────┐
        │ bootstrap/01-catalog-gitrepository.yaml          │
        │   → GitRepository `nkp-virtual-catalog` in       │
        │     `kommander-default-workspace` namespace.     │
        └─────────────────────────┬────────────────────────┘
                                  │
                                  ▼
        ┌──────────────────────────────────────────────────┐
        │ bootstrap/02-clusterapp.yaml                     │
        │   → ClusterApp `nkp-etcd-maintenance-0.3.0`,     │
        │     sourceRef = GitRepository above.             │
        │   → Now visible in NKP dashboard under           │
        │     Workspace > Applications.                    │
        └─────────────────────────┬────────────────────────┘
                                  │
              ┌───────────────────┴──────────────────┐
              ▼                                      ▼
   ┌─────────────────────┐         ┌───────────────────────────────┐
   │ Operator clicks     │         │ bootstrap/03-appdeployment.yaml│
   │ "Deploy" in NKP UI  │         │ (optional kubectl path)        │
   └─────────┬───────────┘         └───────────────┬───────────────┘
             │                                     │
             └─────────────────┬───────────────────┘
                               ▼
        ┌──────────────────────────────────────────────────┐
        │ AppDeployment `nkp-etcd-maintenance`             │
        │   → Kommander reads applications/.../0.3.0/      │
        │   → Applies cm.yaml + HelmRelease.               │
        │   → HelmRelease's chart GitRepository pulls      │
        │     `charts/nkp-etcd-maintenance/` from THIS repo│
        │   → Flux helm-controller renders + applies.      │
        │   → CronJobs land in `kube-system`.              │
        └──────────────────────────────────────────────────┘
```

## Register the catalog (one-time)

1. Push this repo to a Git URL Kommander can reach. Three options:

   | Where | Notes |
   |---|---|
   | **Your GitHub fork** | Easiest. Public repo or with a `gitSecretRef` on the `GitRepository`. |
   | **In-cluster `git-operator-git`** | No external dependency; requires admin to push. |
   | **`oci://` registry** | Replace `kind: GitRepository` with `kind: OCIRepository` in `01-...yaml`. |

2. Edit `bootstrap/01-catalog-gitrepository.yaml`:
   - `spec.url` — your git URL (e.g. `https://github.com/<you>/nkp-virtual-catalog.git`).
   - `spec.ref.branch` — typically `main`.

3. Edit `bootstrap/02-clusterapp.yaml` — no change needed unless renaming.

4. Apply:
   ```bash
   kubectl apply -f bootstrap/01-catalog-gitrepository.yaml
   kubectl apply -f bootstrap/02-clusterapp.yaml
   ```

5. The app now appears in the NKP dashboard:
   `Workspace (kommander-default-workspace) > Applications > NKP etcd Maintenance (TEST CATALOG)`.

## Deploy the app

### Option A — Dashboard

1. In the NKP UI, navigate to `Workspace > Applications`.
2. Find "NKP etcd Maintenance (TEST CATALOG)".
3. Click **Deploy**. Optionally provide an overrides `ConfigMap` with a `values.yaml` key.
4. Wait ~30 s for the HelmRelease to reconcile.

### Option B — kubectl

```bash
kubectl apply -f bootstrap/03-appdeployment.yaml
```

## Verify the install

```bash
# AppDeployment reaches Synced
kubectl -n kommander-default-workspace get appdeployment nkp-etcd-maintenance -w

# HelmRelease reaches Ready
kubectl -n kommander-default-workspace get helmrelease nkp-etcd-maintenance -w

# CronJobs ship into kube-system
kubectl -n kube-system get cronjob
# expect: nkp-etcd-defrag (always), nkp-etcd-snapshot (only if snapshot.enabled=true)
```

## Override the defaults

Create a ConfigMap with a `values.yaml` key (any subset of the chart's
`values.yaml` is acceptable):

```bash
cat > my-overrides.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nkp-etcd-maintenance-overrides
  namespace: kommander-default-workspace
data:
  values.yaml: |
    defragmentation:
      schedule: "*/15 * * * *"   # aggressive cadence for testing
    snapshot:
      enabled: true
YAML

kubectl apply -f my-overrides.yaml
kubectl -n kommander-default-workspace annotate helmrelease nkp-etcd-maintenance \
  reconcile.fluxcd.io/requestedAt="$(date -u +%FT%TZ)" --overwrite
```

The HelmRelease will re-render with overrides layered on top of the catalog
defaults (which are themselves layered on top of the chart's bundled
`values.yaml`).

## Uninstall

```bash
# Removes the install but keeps the catalog registration:
kubectl delete -f bootstrap/03-appdeployment.yaml

# Removes the catalog entry too:
kubectl delete -f bootstrap/02-clusterapp.yaml
kubectl delete -f bootstrap/01-catalog-gitrepository.yaml
```

## How this differs from the production catalog

| Aspect | Production (`nutanix-cloud-native/nkp-nutanix-product-catalog`) | This virtual catalog |
|---|---|---|
| Chart source | OCIRepository on `harbor.eng.nutanix.com` | GitRepository on `charts/nkp-etcd-maintenance/` in this repo |
| External registry needed | Yes (Harbor or GHCR) | No |
| PR cadence | Standard PR review | Push directly to your fork; reconcile in seconds |
| `displayName` | "NKP etcd Maintenance" | "NKP etcd Maintenance (TEST CATALOG)" — to avoid UI confusion |
| `type` annotation | nkp-catalog | custom |

Use the production catalog for customer-facing releases; use this one for
local iteration, screenshots, demos, and end-to-end install verification
before raising a PR upstream.
