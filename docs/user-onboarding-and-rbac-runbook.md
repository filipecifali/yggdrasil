# Comprehensive Runbook: Adding & Managing Users Across Yggdrasil

This operational runbook provides clear, step-by-step procedures for provisioning, modifying, and deprovisioning users across all components in the **Yggdrasil** sovereign cluster.

---

## 1. Centralized Identity Architecture (Authentik)

Yggdrasil uses **Authentik** (`auth.yggdrasil.local`) as the authoritative sovereign Identity Provider (IdP). Authentication across services follows two main patterns:

```
                                  +---------------------------------------+
                                  |     AUTHENTIK IDENTITY PROVIDER       |
                                  |     (auth.yggdrasil.local)            |
                                  +---------------------------------------+
                                      /              |               \
                   (OIDC / OAuth2)   /               |                \   (Forward-Auth via
                                    /        (Direct Users)            \   Envoy SecurityPolicy)
                                   v                 |                  v
                +----------------------+             |           +-----------------------+
                | 1. Kubernetes API    |             |           | 6. VictoriaMetrics UI |
                | 2. Forgejo Git Server|             |           | 7. VictoriaLogs UI    |
                | 3. Harbor Registry   |             |           | 8. VictoriaTraces UI  |
                +----------------------+             |           +-----------------------+
                                                     v
                                       +---------------------------+
                                       | 4. HashiCorp Vault        |
                                       | 5. Zulip Threaded Chat    |
                                       | 9. Roundcube Webmail      |
                                       | 10. PostgreSQL / CloudNativePG
                                       | 11. RabbitMQ Broker       |
                                       | 12. SeaweedFS S3 Storage  |
                                       +---------------------------+
```

---

## 2. Component 1: Kubernetes API Access

Kubernetes API authentication uses **Authentik OIDC** with the `groups` claim mapped to Kubernetes RBAC `ClusterRoles` and `RoleBindings`.

### Standard RBAC Groups

| Authentik Group | Target Scope | Assigned Role | Typical Persona |
| :--- | :--- | :--- | :--- |
| **`cluster-admins`** | Cluster-Wide | `ClusterRole/cluster-admin` | Principal Cloud Architect, Root Operator |
| **`platform-ops`** | Cluster-Wide | `ClusterRole/yggdrasil-platform-operator` | SRE, Infrastructure & Security Engineers |
| **`auditors`** | Cluster-Wide | `ClusterRole/view` | Compliance, Security Auditors (Read-Only) |
| **`dev-web`** | `web-system` | `ClusterRole/admin` | Web & Frontend Application Developers |
| **`dev-git`** | `git-system` | `ClusterRole/admin` | Forgejo GitOps Developers |
| **`dev-chat`** | `chat-system` | `ClusterRole/admin` | Communications & Zulip Engineers |
| **`dev-mail`** | `mail-system` | `ClusterRole/admin` | Mail Server Ops |
| **`dev-sample`** | `sample-app` | `ClusterRole/admin` | Ephemeral App Developers |

### Procedure: Onboard a New Kubernetes User

#### Step 1: Create the User in Authentik
1. Navigate to `https://auth.yggdrasil.local` and log in as administrator.
2. In the Admin Interface, go to **Directory** → **Users** → **Create**.
3. Fill in:
   - **Username**: `jane.doe`
   - **Name**: `Jane Doe`
   - **Email**: `jane.doe@yggdrasil.local`
4. In the **Groups** tab, select the appropriate group(s) (e.g., `cluster-admins`, `platform-ops`, or `dev-web`).
5. Click **Create**, then select the user and set an initial password or send an enrollment invitation.

#### Step 2: Generate the User's Kubeconfig
Run the automated kubeconfig generator:
```bash
./scripts/generate-user-kubeconfig.sh oidc jane.doe /path/to/jane.kubeconfig
```

#### Step 3: User Login & Verification
The user installs `kubelogin` (`kubectl oidc-login`) and runs:
```bash
export KUBECONFIG=/path/to/jane.kubeconfig
kubectl get pods -A
```
*A browser window opens to Authentik. Once authenticated, the user receives an ID token, and `kubectl` executes under their assigned RBAC permissions.*

#### Alternative: Headless CI/CD / Automation User (Mutual TLS Certificate)
If provisioning a non-human CI pipeline or offline auditor:
```bash
./scripts/generate-user-kubeconfig.sh cert ci-runner auditors /path/to/ci-runner.kubeconfig
```

---

## 3. Component 2: Forgejo Git & CI/CD

Forgejo (`git.yggdrasil.local`) uses Authentik OIDC for Single Sign-On (SSO).

### Procedure: Provisioning Users
1. **Interactive SSO (Self-Provisioning)**:
   - When a user created in Authentik visits `https://git.yggdrasil.local`, they click **Sign in with Authentik**.
   - Forgejo automatically provisions their Git account on first login and links their email and display name.
2. **Elevating User to Git Administrator (CLI)**:
   To promote a user to Forgejo instance administrator:
   ```bash
   kubectl -n git-system exec -it deploy/forgejo -- \
     su git -c "gitea admin user change-password --username jane.doe --admin"
   ```
3. **Creating a Machine / CI Service Account (CLI)**:
   ```bash
   kubectl -n git-system exec -it deploy/forgejo -- \
     su git -c "gitea admin user create --username automation-bot --email bot@yggdrasil.local --password 'SecureBotPass123!' --must-change-password=false"
   ```

---

## 4. Component 3: Harbor Container & Helm Registry

Harbor (`registry.yggdrasil.local`) synchronizes authentication via OIDC or localized accounts.

### Procedure: Provisioning Users
1. **Interactive SSO**:
   - Any user in Authentik can navigate to `https://registry.yggdrasil.local` and select **LOG IN VIA OIDC PROVIDER**.
2. **Granting Project Roles**:
   - Harbor Administrator navigates to **Projects** → select project (e.g., `library`) → **Members** → **+ User**.
   - Search for `jane.doe` and assign role:
     - **Project Admin**: Full image and vulnerability policy management.
     - **Developer**: Pull and push container images and Helm charts.
     - **Guest / Limited Guest**: Pull-only access.
3. **Robot Accounts (CI / Kubernetes Image Pull Secrets)**:
   - In Harbor, navigate to **Projects** → **Robot Accounts** → **New Robot Account**.
   - Set Name (e.g., `sample-app-puller`), select permissions (`repository:pull`), and set expiration.
   - Store the generated Secret in HashiCorp Vault under `secret/registry/credentials`.

---

## 5. Component 4: HashiCorp Vault

Vault uses its internal AppRole, Token, or Userpass engines, backed by RBAC policies.

### Procedure: Adding a Human User to Vault
1. Port-forward or access Vault CLI:
   ```bash
   export VAULT_ADDR="https://vault.yggdrasil.local"
   # or internally via pod:
   kubectl -n vault-system exec -it vault-0 -- sh
   ```
2. Enable `userpass` auth method (if not already enabled):
   ```bash
   vault auth enable userpass
   ```
3. Define an ACL policy (e.g., `developer-policy`):
   ```bash
   vault policy write dev-web-policy - <<EOF
   path "secret/data/web/*" {
     capabilities = ["create", "read", "update", "delete", "list"]
   }
   path "secret/metadata/web/*" {
     capabilities = ["list", "read"]
   }
   EOF
   ```
4. Create the user:
   ```bash
   vault write auth/userpass/users/jane.doe \
     password="TemporaryUserPassword2026!" \
     policies="dev-web-policy"
   ```

---

## 6. Component 5: Zulip Threaded Team Chat

Zulip (`chat.yggdrasil.local`) manages internal organization users.

### Procedure: Inviting & Creating Users
1. **Web Admin UI**:
   - Organization Administrator logs in to `https://chat.yggdrasil.local`.
   - Go to **Gear Icon (top right)** → **Organization settings** → **Users** → **Invite users**.
   - Enter email: `jane.doe@yggdrasil.local`.
   - Assign Initial Role: **Member**, **Moderator**, or **Organization Administrator**.
   - Select default streams to join (`#general`, `#announcements`, `#alerts`).
2. **CLI Creation (Internal Script)**:
   ```bash
   kubectl -n chat-system exec -it deploy/zulip -- \
     su zulip -c "/home/zulip/deployments/current/manage.py generate_multiuse_invite_link"
   ```

---

## 7. Component 6: VictoriaMetrics, VictoriaLogs & VictoriaTraces

Access to monitoring dashboards (`metrics.yggdrasil.local`, `logs.yggdrasil.local`, `traces.yggdrasil.local`) is gated at the edge by **Envoy Gateway SecurityPolicy** with **Authentik Forward-Auth**.

### Procedure: Authorizing Users for Monitoring
1. In Authentik, open **Directory** → **Users** → edit user.
2. Ensure the user belongs to either **`cluster-admins`**, **`platform-ops`**, or **`auditors`**.
3. When the user visits `https://metrics.yggdrasil.local` or `https://logs.yggdrasil.local`:
   - Envoy Gateway intercepts the request and queries Authentik (`/outpost.goauthentik.io/auth/envoy`).
   - If the user is signed in to Authentik and belongs to an authorized group, Envoy injects `X-authentik-username: jane.doe` and forwards the request to the upstream VictoriaMetrics service.

---

## 8. Component 7: Grafana

Grafana (`grafana.yggdrasil.local`) synchronizes roles directly from Authentik OIDC or internal admin provisioning.

### Procedure: Adding Grafana Users & Role Mapping
1. **Automatic OIDC Role Sync**:
   - Grafana is configured with Generic OAuth targeting Authentik.
   - When a user logs in, their Authentik groups determine their Grafana Org Role:
     - Group `cluster-admins` → Grafana **Admin**
     - Group `platform-ops` → Grafana **Editor**
     - Group `auditors` or developers → Grafana **Viewer**
2. **Local Administrator Creation (Fallback)**:
   ```bash
   kubectl -n monitoring-system exec -it deploy/grafana -- \
     grafana-cli admin reset-admin-password "NewAdminPass2026!"
   ```

---

## 9. Component 8: Email & Mailserver (`docker-mailserver` / Roundcube)

Mail accounts are hosted in `mail-system` using `docker-mailserver`.

### Procedure: Creating a Mailbox
1. Execute the `setup-cli` utility on the active mailserver pod:
   ```bash
   kubectl -n mail-system exec -it deploy/mailserver -- \
     setup email add jane.doe@yggdrasil.local "SecureMailPassword2026!"
   ```
2. Add any required mail aliases:
   ```bash
   kubectl -n mail-system exec -it deploy/mailserver -- \
     setup alias add security@yggdrasil.local jane.doe@yggdrasil.local
   ```
3. Verify account creation:
   ```bash
   kubectl -n mail-system exec -it deploy/mailserver -- setup email list
   ```
4. The user can now log into Roundcube Webmail at `https://mail.yggdrasil.local` using their full email and password.

---

## 10. Component 9: PostgreSQL Databases (CloudNativePG)

Databases are managed by CloudNativePG (`storage-system` and `auth-system`).

### Procedure: Creating a Database User
1. Connect to the primary PostgreSQL pod:
   ```bash
   kubectl -n storage-system exec -it yggdrasil-pg-1 -- psql -U postgres
   ```
2. Create user with `scram-sha-256` password encryption and least-privilege grants:
   ```sql
   CREATE USER reporting_user WITH PASSWORD 'StrongPassword2026!';
   GRANT CONNECT ON DATABASE app TO reporting_user;
   \c app
   GRANT USAGE ON SCHEMA public TO reporting_user;
   GRANT SELECT ON ALL TABLES IN SCHEMA public TO reporting_user;
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO reporting_user;
   ```
3. Store the database credentials in HashiCorp Vault.

---

## 11. Component 10: RabbitMQ Message Broker

RabbitMQ is used for Celery queues and messaging (`chat-system` and tenant namespaces).

### Procedure: Creating a Broker User
1. Execute `rabbitmqctl` inside the RabbitMQ pod:
   ```bash
   kubectl -n chat-system exec -it zulip-rabbitmq-0 -- \
     rabbitmqctl add_user jane_worker "WorkerPassword2026!"
   ```
2. Set permissions on the target vhost:
   ```bash
   kubectl -n chat-system exec -it zulip-rabbitmq-0 -- \
     rabbitmqctl set_permissions -p "/" jane_worker ".*" ".*" ".*"
   ```
3. Set user tags (e.g. `monitoring` or `management` if UI access is needed):
   ```bash
   kubectl -n chat-system exec -it zulip-rabbitmq-0 -- \
     rabbitmqctl set_user_tags jane_worker management
   ```

---

## 12. Component 11: SeaweedFS S3 Object Storage

SeaweedFS provides S3-compatible storage (`storage-system`).

### Procedure: Creating an S3 Access Key & Secret
1. Access the SeaweedFS Master / Filer:
   ```bash
   kubectl -n storage-system exec -it seaweedfs-filer-0 -- weed shell
   ```
2. In the Weed shell, create IAM S3 credentials:
   ```text
   s3.configure -user jane_s3 -actions Read,Write,List -buckets sample-app-demo
   ```
3. Retrieve generated `AccessKey` and `SecretKey` and store them in Vault under `secret/storage/s3-credentials`.

---

## 13. User Offboarding & Deprovisioning Checklist

To completely offboard a user from Yggdrasil:

1. **Authentik (Primary Kill-Switch)**:
   - Navigate to `auth.yggdrasil.local` → **Directory** → **Users** → Select user → **Deactivate User** or **Delete**.
   - *Instantly terminates active SSO sessions and blocks access to Kubernetes API, Forgejo, Harbor, VictoriaMetrics, Grafana, and Web Services.*
2. **Kubernetes Headless Certs**:
   - If user had X509 certificates, delete any active client bindings and revoke cert via PKI if applicable.
3. **Mailbox**:
   - `kubectl -n mail-system exec -it deploy/mailserver -- setup email del jane.doe@yggdrasil.local`
4. **Database & S3**:
   - Revoke DB roles: `DROP USER IF EXISTS reporting_user;`
   - Remove S3 IAM keys in SeaweedFS.
5. **Vault**:
   - `vault delete auth/userpass/users/jane.doe`
