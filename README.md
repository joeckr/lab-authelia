# lab-authelia

A hardened, self-contained Helm chart and documentation for deploying **Authelia** with **LLDAP** on Kubernetes — tailored for a homelab running **Talos Linux**, **Cloudflare Tunnel** forwarding to a **Traefik Kubernetes Gateway** (`gateway.networking.k8s.io/v1`), and **Longhorn** persistent storage.

> [!IMPORTANT]
> **Update the Hostname & Domain for Your Environment**
> The default configuration in [`chart/values.yaml`](chart/values.yaml) uses **`sso.joeckr.dev`**, cookie domain **`joeckr.dev`**, and LDAP Base DN **`dc=joeckr,dc=dev`**. If you are deploying this chart in your own homelab, override `authelia.hostname`, `authelia.domain`, and `lldap.baseDn` (plus `authelia.httproute.parentRefs` if your Traefik Gateway uses a different name or namespace) before installing.

---

## Architecture

```text
Internet
   │
   ▼
Cloudflare Edge (TLS termination)
   │
   ▼
Cloudflare Tunnel (cloudflared)
   │  forwards sso.joeckr.dev
   ▼
Traefik Kubernetes Gateway (Gateway API)
   │  HTTPRoute (sso.joeckr.dev)
   ▼
Authelia Service (:9091) ──▶ Authelia Pod (SQLite on Longhorn PVC)
                                │
                                │ LDAP (:3890)
                                ▼
                             LLDAP Service (:3890 / :17170) ──▶ LLDAP Pod (SQLite on Longhorn PVC)
```

### Key Features

- **Bundled Authelia + LLDAP**: Pre-wired LDAP integration (`authentication_backend.ldap.implementation: lldap`) with both workloads managed in a single Helm release.
- **Kubernetes Gateway API (`HTTPRoute`)**: Routes `sso.joeckr.dev` through your Traefik Kubernetes Gateway (`gateway.networking.k8s.io/v1`). Optional `HTTPRoute` for LLDAP Web UI (disabled by default for security).
- **Longhorn Persistence**: Dedicated `ReadWriteOnce` Longhorn PVCs for Authelia's SQLite database (`/data/db.sqlite3`) and LLDAP's SQLite directory database (`/data`). Deployments use `strategy.type: Recreate` to avoid RWO volume attachment deadlocks during rollouts.
- **Hardened for Talos Linux & PSS `restricted`**:
  - Rootless images (`ghcr.io/authelia/authelia` and `ghcr.io/lldap/lldap:latest-alpine-rootless`).
  - `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile.type: RuntimeDefault`, and `automountServiceAccountToken: false`.
  - Secrets mounted as read-only files (`_FILE` env vars) for Authelia rather than exposed in `configuration.yml` or plaintext environment variables.
  - Control-plane/master tolerations included for compact Talos homelab clusters.

---

## Directory Structure

```text
.
├── .github/
│   └── workflows/
│       ├── lint.yml                     # Lints workflows, commits, and shell scripts
│       ├── security.yml                 # Scans for secrets and audits workflow security
│       ├── release.yml                  # Semantic release and Helm chart publishing to GHCR
│       └── test_release.yml             # PR dry-run test for releases and chart packaging
├── chart/
│   ├── Chart.yaml                       # Helm chart metadata
│   ├── values.yaml                      # Default values (update hostname/domain/secrets)
│   ├── .helmignore                      # Ignore rules for chart packaging
│   └── templates/
│       ├── _helpers.tpl                 # Shared naming, label, and LDAP helpers
│       ├── NOTES.txt                    # Post-install instructions
│       ├── authelia-configmap.yaml      # Authelia configuration.yml
│       ├── authelia-deployment.yaml     # Authelia Deployment (PSS restricted)
│       ├── authelia-httproute.yaml      # Gateway API HTTPRoute for sso.joeckr.dev
│       ├── authelia-pvc.yaml            # Longhorn PVC for Authelia SQLite & notifier
│       ├── authelia-secret.yaml         # Authelia secrets (when existingSecret is unset)
│       ├── authelia-service.yaml        # Authelia ClusterIP Service (:9091)
│       ├── lldap-deployment.yaml        # LLDAP Deployment (PSS restricted, rootless)
│       ├── lldap-httproute.yaml         # Optional Gateway API HTTPRoute for LLDAP UI
│       ├── lldap-pvc.yaml               # Longhorn PVC for LLDAP database
│       ├── lldap-secret.yaml            # LLDAP secrets (when existingSecret is unset)
│       └── lldap-service.yaml           # LLDAP ClusterIP Service (:3890, :17170)
├── hk.pkl                               # hk git hooks and checks configuration
├── mise.toml                            # Mise tools and tasks
└── README.md
```

---

## Prerequisites

1. **Talos Linux Kubernetes cluster** with `kubectl` and `helm` (`>= 3.14`) configured.
2. **Longhorn** installed with a `longhorn` `StorageClass` (or override `global.storageClass`).
3. **Traefik with Kubernetes Gateway API** enabled and a `Gateway` resource created (defaults expect `name: traefik-gateway` in namespace `gateway`, listener `web`).
   - Ensure the `Gateway` listener allows routes from the namespace where you install this chart (e.g., `allowedRoutes.namespaces.from: All` or `Selector`).
4. **Cloudflare Tunnel (`cloudflared`)** configured to forward your Authelia hostname (`sso.joeckr.dev`) to your Traefik Kubernetes Gateway service:
   - In Cloudflare Zero Trust -> **Networks** -> **Tunnels** -> **Public Hostnames**:
     - **Subdomain / Domain**: `sso.joeckr.dev` (replace with your own domain)
     - **Service**: `http://gateway-traefik.gateway.svc.cluster.local:80` (adjust to match your Traefik service name and namespace).
   - Ensure Traefik's `web` entrypoint trusts `X-Forwarded-*` headers from your `cloudflared` pods (`ports.web.forwardedHeaders.trustedIPs` set to your cluster pod CIDR, or `insecure: true` if internal-only) so Authelia sees the correct client IP and `https` scheme.

---

## Installation

### 1. Create a Namespace

Optionally label the namespace to enforce Kubernetes Pod Security Standards (`restricted`):

```sh
kubectl create namespace authelia
kubectl label namespace authelia \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

### 2. Prepare Secrets (Recommended: Pre-Created Kubernetes Secrets)

Using `existingSecret` keeps sensitive values out of your Helm values files and Git history. Generate strong random secrets and create both Kubernetes Secrets:

```sh
# Generate random secrets
AUTHELIA_JWT_SECRET=$(openssl rand -hex 32)
AUTHELIA_SESSION_SECRET=$(openssl rand -hex 32)
AUTHELIA_STORAGE_KEY=$(openssl rand -hex 32)
LLDAP_JWT_SECRET=$(openssl rand -hex 32)
LLDAP_KEY_SEED=$(openssl rand -hex 32)
LLDAP_ADMIN_PASSWORD=$(openssl rand -base64 24)

# Create LLDAP Secret
kubectl -n authelia create secret generic lldap-secrets \
  --from-literal=jwt-secret="${LLDAP_JWT_SECRET}" \
  --from-literal=key-seed="${LLDAP_KEY_SEED}" \
  --from-literal=admin-password="${LLDAP_ADMIN_PASSWORD}"

# Create Authelia Secret (uses LLDAP admin password for initial bootstrap)
kubectl -n authelia create secret generic authelia-secrets \
  --from-literal=jwt-secret="${AUTHELIA_JWT_SECRET}" \
  --from-literal=session-secret="${AUTHELIA_SESSION_SECRET}" \
  --from-literal=storage-encryption-key="${AUTHELIA_STORAGE_KEY}" \
  --from-literal=ldap-password="${LLDAP_ADMIN_PASSWORD}"
```

### 3. Create a Values Override File

Create a local `my-values.yaml` (do not commit secrets to Git). Update the hostname, domain, Base DN, and Gateway `parentRefs` as needed:

```yaml
global:
  timezone: "America/New_York"
  storageClass: "longhorn"

authelia:
  # Update these to your own domain!
  hostname: "sso.joeckr.dev"
  domain: "joeckr.dev"
  existingSecret: "authelia-secrets"
  httproute:
    enabled: true
    parentRefs:
      - name: traefik-gateway
        namespace: gateway
        sectionName: web

lldap:
  enabled: true
  # Update this to match your own domain!
  baseDn: "dc=joeckr,dc=dev"
  existingSecret: "lldap-secrets"
```

### 4. Deploy with Helm

Install from the local repository:

```sh
helm upgrade --install authelia chart/ \
  --namespace authelia \
  --values my-values.yaml
```

Or install directly from the published OCI chart on GHCR:

```sh
helm upgrade --install authelia oci://ghcr.io/joeckr/charts/lab-authelia \
  --namespace authelia \
  --values my-values.yaml
```

### 5. Verify the Deployment

```sh
# Check pods and PVCs
kubectl -n authelia get pods,pvc,httproute

# Check Authelia logs
kubectl -n authelia logs -l app.kubernetes.io/name=authelia -f

# Check LLDAP logs
kubectl -n authelia logs -l app.kubernetes.io/name=lldap -f
```

---

## Post-Install LLDAP Setup

By default, the LLDAP Web UI `HTTPRoute` is disabled so the directory admin panel is not exposed publicly.

1. **Port-forward to LLDAP**:
   ```sh
   kubectl -n authelia port-forward svc/authelia-lldap 17170:17170
   ```
   Open [http://localhost:17170](http://localhost:17170) and sign in with username `admin` and the `admin-password` you generated.

2. **Create Your Users & Groups**:
   - Create your personal user account (with an email address and password).
   - Create any groups you want to use in Authelia access control rules (e.g., `admins`, `homelab`).

3. **(Recommended) Create a Dedicated Authelia Bind Account**:
   - Instead of having Authelia bind as `admin`, create a dedicated user in LLDAP (e.g., `authelia`) and add it to the **`lldap_password_manager`** group (allows password resets via Authelia) or **`lldap_strict_readonly`** group (read-only authentication).
   - Update `ldap-password` in your `authelia-secrets` Secret with the new user's password and set `authelia.ldap.bindUserDn` in your values file:
     ```yaml
     authelia:
       ldap:
         bindUserDn: "uid=authelia,ou=people,dc=joeckr,dc=dev"
     ```
   - Re-run `helm upgrade`.

4. **Viewing 2FA / Password Reset Notifications (Filesystem Notifier)**:
   When using the default filesystem notifier, Authelia writes links (such as TOTP/WebAuthn registration links) to `/data/notification.txt` on its Longhorn PVC:
   ```sh
   kubectl -n authelia exec deploy/authelia -- cat /data/notification.txt
   ```
   To send real emails instead, set `authelia.notifier.smtp.enabled: true` and provide SMTP credentials in `values.yaml` / `authelia-secrets`.

---

## Key Configuration Values

| Value | Default | Description |
|---|---|---|
| `global.timezone` | `"UTC"` | Timezone (`TZ`) for both Authelia and LLDAP |
| `global.storageClass` | `"longhorn"` | StorageClass for Longhorn PVCs |
| `authelia.hostname` | `"sso.joeckr.dev"` | Public Authelia hostname (**update for your domain**) |
| `authelia.domain` | `"joeckr.dev"` | Cookie domain protected by Authelia (**update for your domain**) |
| `authelia.existingSecret` | `""` | Pre-existing Kubernetes Secret name for Authelia |
| `authelia.httproute.enabled` | `true` | Create Gateway API `HTTPRoute` for Authelia |
| `authelia.httproute.parentRefs` | `traefik-gateway` in `gateway` (`web`) | Target Traefik Kubernetes `Gateway` reference |
| `authelia.persistence.size` | `1Gi` | Longhorn PVC size for Authelia SQLite DB & notifier |
| `authelia.accessControl.defaultPolicy` | `"two_factor"` | Default Authelia access control policy |
| `lldap.enabled` | `true` | Deploy bundled LLDAP alongside Authelia |
| `lldap.baseDn` | `"dc=joeckr,dc=dev"` | LDAP Base DN (**update for your domain**) |
| `lldap.existingSecret` | `""` | Pre-existing Kubernetes Secret name for LLDAP |
| `lldap.persistence.size` | `1Gi` | Longhorn PVC size for LLDAP SQLite DB |
| `lldap.httproute.enabled` | `false` | Optionally expose LLDAP Web UI via `HTTPRoute` |

See [`chart/values.yaml`](chart/values.yaml) for the complete list of configurable options.

---

## Security & Hardened Pod Architecture (Kubernetes PSS `restricted`)

Both Authelia and LLDAP pods comply with the Kubernetes **Pod Security Standards `restricted`** profile out of the box on Talos Linux:

| Security Dimension | Restricted Standard Requirement | Implementation in This Chart |
|---|---|---|
| **Workload Execution** | Non-root UID (`runAsNonRoot: true`) | `runAsNonRoot: true`, `runAsUser: 1031`, `runAsGroup: 1031`, `fsGroup: 1031` |
| **Root Filesystem** | Hardened per workload | `readOnlyRootFilesystem: true` on LLDAP; `false` on Authelia (SQLite runtime) |
| **Capabilities** | Must drop `ALL` capabilities | `capabilities.drop: ["ALL"]` |
| **Privilege Escalation** | Prohibited | `allowPrivilegeEscalation: false` |
| **Seccomp Profile** | `RuntimeDefault` or `Localhost` | `seccompProfile: { type: RuntimeDefault }` |
| **Service Account Token** | Disabled unless required | `automountServiceAccountToken: false` |
| **Port Binding** | Unprivileged (> 1024) | Authelia `9091`, LLDAP `3890` / `17170` |
| **Routing Layer** | Kubernetes Gateway API | `gateway.networking.k8s.io/v1` `HTTPRoute` |

---

## Local Preview (`compose.yml`)

You can preview Authelia + LLDAP locally before deploying to your cluster:

```sh
# Start LLDAP and Authelia
mise run compose
# or: podman compose up -d

# Tail logs
mise run logs

# Stop and remove containers
mise run down
```

- **Authelia Portal**: [http://127.0.0.1:9091](http://127.0.0.1:9091) *(use `127.0.0.1`, not `localhost`, to match the configured session cookie domain)*
- **LLDAP Admin UI**: [http://localhost:17170](http://localhost:17170) (default local dev credentials: `admin` / `localdevpass`)
- **View local 2FA/reset notifications**: `podman exec authelia cat /data/notification.txt`

---

## Local Development & Tasks

### Setup

```sh
# Install tools and git hooks
mise run install
```

### Available Tasks

Run tasks with `mise run <task>`:

| Task | Description | Command |
|---|---|---|
| `install` | Install tools and set up git hooks | `hk install --mise` |
| `hk` (or `check`) | Run all linters and hook checks | `hk check --all` |
| `compose` | Start local LLDAP + Authelia preview stack | `podman compose up -d` |
| `down` | Stop local Podman Compose stack | `podman compose down` |
| `logs` | View Podman Compose logs | `podman compose logs -f` |
| `helm-d` | Build Helm chart dependencies | `helm dependency build chart/` |
| `helm-l` | Lint Helm chart | `helm lint chart/` |
| `helm-t` | Render Helm chart templates to `rendered.yaml` | `helm template test chart/ > rendered.yaml` |
| `helm-i` | Install Helm chart to current Kubernetes cluster | `helm install test chart/` |
| `helm-u` | Uninstall Helm chart release from cluster | `helm uninstall test` |
| `trivy-fs` | Scan repository filesystem for security vulnerabilities | `trivy fs .` |

---

## Conventional Commits & Releases

Commits must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:
- `feat: add new feature` -> Triggers a **minor** release (e.g., `v0.1.0` -> `v0.2.0`).
- `fix: resolve issue` -> Triggers a **patch** release (e.g., `v0.1.0` -> `v0.1.1`).
- `feat!: breaking change` -> Triggers a **major** release.
- `chore:`, `docs:`, `ci:`, `test:`, `refactor:` -> Maintenance changes (no release bump).

Upon merging to `main`, the `release.yml` workflow automatically computes the next version, updates `version` and `appVersion` in `chart/Chart.yaml`, creates a Git tag, publishes a GitHub Release, and packages and pushes the Helm chart to GHCR.

## Support

If you find this project useful, consider supporting my work on [Ko-fi](https://ko-fi.com/joeckr):

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/joeckr)

## License

Please refer to the `LICENSE` file for details.
