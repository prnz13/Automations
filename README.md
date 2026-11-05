# VLMS deployment to Azure Ubuntu with GitHub Actions

Deploy release **v5.0.1.1.2** from the **Automations** repository to an existing Azure Ubuntu VM. The workflow transfers deployment files and a secret-backed `.env`, authenticates to Azure Container Registry, runs `ai-start.sh`, merges five Nginx location blocks, restarts Nginx, waits 60 seconds, and checks four HTTPS readiness endpoints.

This guide describes the supplied `deploy.yml`. It does not create the Azure VM, install Docker or Azure CLI, provision application dependencies, or build container images.

## 1. Deployment settings

| Setting | Current value |
|---|---|
| Repository | `Automations` |
| Workflow | `.github/workflows/deploy.yml` |
| Trigger | Manual: `workflow_dispatch` |
| Runner | GitHub-hosted `ubuntu-latest` |
| Ubuntu user | `vgadmin` |
| Repository source directory | `deployments/v5.0.1.1.2` |
| Ubuntu deployment directory | `/home/vgadmin/VLMS/v5.0.1.1.2` |
| Start script | `ai-start.sh` |
| Registry name | `vgvalcontainer` |
| Registry login server | `vgvalcontainer.azurecr.io` |
| Deployment service principal | `VGUSTESTAI` |
| Docker network | Existing external network `ai_net` |
| Application data path | `/AI-DATA`, mounted as `/mnt` in application containers |
| Nginx container | `ai_nginx` |
| Host Nginx configuration | `/home/vgadmin/Common-AI/nginx/nginx.conf` |
| Same configuration inside Nginx | `/etc/nginx/conf.d/default.conf` |
| Release URL prefix | `/v5.0.1.1.2/` |
| Hostname source | `server_name` in the merged Nginx configuration |
| Current application hostname | `VGUSTESTSVRAI01.valgenesis.net` |
| SSH endpoint supplied for this VM | `135.232.202.3`, port `22`; verify it is still assigned to the intended VM |
| Job timeout | 45 minutes |

The Ubuntu destination directory and the repository source directory are separate settings. A directory on the VM does not satisfy the repository file-validation step.

## 2. Repository structure

Create these files in the branch you will deploy:

```text
.github/workflows/deploy.yml
deployments/v5.0.1.1.2/ai-start.sh
deployments/v5.0.1.1.2/ai-stop.sh                         # Optional; not called by the workflow
deployments/v5.0.1.1.2/content-generation-docker-compose.yaml
deployments/v5.0.1.1.2/execution-assisstant-docker-compose.yaml
deployments/v5.0.1.1.2/ingestion-docker-compose.yaml
deployments/v5.0.1.1.2/sga-docker-compose.yaml
deployments/v5.0.1.1.2/smart-generation-docker-compose.yaml
README.md
```

Use the exact filenames above, including `execution-assisstant`. Remove upload suffixes such as `(1)` from repository filenames. Store shell scripts with Linux LF line endings.

Keep the real `.env` and deployment private key out of Git. Suggested `.gitignore` entries:

```gitignore
.env
.env.*
!.env.example
github-actions-vlms
github-actions-vlms.pub
```

Use `.env.example` only for placeholders. The workflow excludes `.env` and `.env.*` from file transfer and generates the real `.env` separately from a secret.

## 3. Ubuntu prerequisites

Run as `vgadmin`:

```bash
for executable in az docker rsync python3 curl flock; do
    command -v "$executable" || break
done

docker compose version
docker info >/dev/null
docker network inspect ai_net
ls -ld /AI-DATA
```

All required commands must be installed, and Docker must be usable without an interactive `sudo` prompt. Install missing components using the official product documentation listed at the end of this guide.

If `vgadmin` is intended to have Docker administration privileges and cannot use Docker:

```bash
sudo usermod -aG docker vgadmin
```

Disconnect and reconnect, then run `docker ps`. Docker group membership grants powerful access to the host; use the approved deployment account.

The external `ai_net` network must already exist. If it is missing, create it using your approved Docker network configuration after checking for subnet overlaps. Do not change an existing shared network's subnet during deployment.

Verify Nginx and its mounts:

```bash
docker inspect ai_nginx --format '{{.State.Running}}'
docker inspect ai_nginx --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker inspect ai_nginx --format '{{json .NetworkSettings.Networks}}'
docker exec ai_nginx nginx -t

test -w /home/vgadmin/Common-AI/nginx/nginx.conf
```

Expected: Nginx is running, is connected to `ai_net`, has the configuration mount shown in section 1, and currently passes `nginx -t`. The deployment account needs permission to edit the file and create backup files in its parent directory.

`/AI-DATA` should be the intended persistent storage mount with suitable application permissions, not merely an empty directory accidentally created in its place. The workflow checks directory existence; it does not verify the underlying disk mount or provision application data.

## 4. Runner-to-VM connectivity

The runner must reach the VM's SSH endpoint. With `ubuntu-latest`, a private VM address is not directly reachable without additional private networking.

Configure the VM/subnet NSGs, host firewall, and any intervening firewall to permit TCP traffic from the deployment runner to the SSH port. Where both subnet and NIC NSGs apply, both must permit the connection.

Standard GitHub-hosted runner addresses can change. A single IP allowed for a previous job may not work for the next one. For persistent IP-based access, use a runner with a static public address or a self-hosted runner with network access to the VM. Changing `runs-on` alone does not configure such a runner.

The supplied workflow does not automatically add or remove Azure NSG rules. Do not assume that the website's HTTPS hostname also provides SSH access: use the actual SSH endpoint in `SSH_HOST`.

The Ubuntu VM also needs outbound connectivity to Azure authentication endpoints, ACR and its image data endpoints, application dependencies, and the HTTPS readiness hostname.

## 5. SSH authentication and server trust

Two different keys are involved:

| Item | Purpose |
|---|---|
| Deployment private key / `SSH_PRIVATE_KEY` | Authenticate the workflow as `vgadmin` |
| Server public host key / `SSH_KNOWN_HOSTS` | Verify that the runner reached the intended server |

### Create and authorize the deployment key

If a working deployment key is already configured, reuse it; do not generate a replacement unnecessarily.

On a trusted administrative machine:

```bash
ssh-keygen -t ed25519 -f github-actions-vlms -C "github-actions-vlms"
```

The supplied workflow expects a key usable without a passphrase. Add the public key (`github-actions-vlms.pub`) to `/home/vgadmin/.ssh/authorized_keys` on the target VM through an existing trusted connection. Preserve any existing authorized keys.

On the VM:

```bash
mkdir -p /home/vgadmin/.ssh
chmod 700 /home/vgadmin/.ssh
chmod 600 /home/vgadmin/.ssh/authorized_keys
```

Ensure these files are owned by the deployment account. Save the entire private key, including its BEGIN/END lines, in `SSH_PRIVATE_KEY`. Never paste the private key into this README, logs, or the repository.

### Create the known_hosts entry

Through a trusted VM session, obtain the host public key and fingerprint:

```bash
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

For the supplied SSH IP and port 22, the secret format is:

```text
135.232.202.3 ssh-ed25519 <complete-server-public-key-base64>
```

Replace the placeholder with the key returned by the server, without angle brackets. Save a single complete line. The final `root@hostname` comment is optional.

For a different hostname or custom port:

```text
[actual-ssh-host]:2222 ssh-ed25519 <complete-server-public-key-base64>
```

For standard port 22, use the plain host rather than `[host]:port`. Match `SSH_HOST` exactly. `vlms-target` is a local workflow alias, not the server name to put in this secret.

Keep `StrictHostKeyChecking yes`. If a host key changes, verify the new fingerprint through trusted access before updating the secret.

## 6. Azure service-principal permissions

Use `VGUSTESTAI` for deployment authentication. Its display name is not the login username: Azure CLI uses its Application (client) ID, Directory (tenant) ID, and a current client secret value.

In Azure Portal:

1. Open **Microsoft Entra ID → App registrations → VGUSTESTAI → Overview**.
2. Obtain the Application (client) ID and Directory (tenant) ID.
3. Obtain a valid client secret value through the approved credential-management process. A secret ID is not the secret value.
4. Open **Container registries → vgvalcontainer → Access control (IAM) → Add role assignment**.
5. Assign the applicable pull role to the `VGUSTESTAI` service principal at the registry scope.

| Registry permissions mode | Pull role |
|---|---|
| RBAC Registry Permissions | `AcrPull` |
| RBAC Registry + ABAC Repository Permissions | `Container Registry Repository Reader`, with access to the required repositories |

Use the current replacement credentials if an earlier secret was exposed. This deployment does not require `az login --identity` or VM managed-identity authentication.

The workflow signs in on the Ubuntu server as the service principal, then runs:

```bash
az acr login --name vgvalcontainer
```

Docker pulls are performed as `vgadmin`, using that user's registry credentials. Azure CLI and Docker login state remain on the VM; the runner's final cleanup removes its temporary SSH files only.

Application Azure credentials inside `.env` serve a separate purpose, such as Key Vault access. They do not automatically authenticate the deployment's Azure CLI session, even if you choose to use the same service principal for both.

## 7. GitHub repository secrets

Open **Automations → Settings → Secrets and variables → Actions → Secrets → New repository secret**.

| Secret | Required value |
|---|---|
| `SSH_HOST` | Reachable SSH IP or DNS name; supplied endpoint: `135.232.202.3` |
| `SSH_PORT` | `22`; workflow defaults to 22 if omitted |
| `SSH_PRIVATE_KEY` | Complete deployment private key |
| `SSH_KNOWN_HOSTS` | Verified host-key entry matching the SSH host and port |
| `ACR_NAME` | `vgvalcontainer` — without `.azurecr.io` |
| `AZURE_CLIENT_ID` | Application (client) ID for `VGUSTESTAI` |
| `AZURE_TENANT_ID` | Directory (tenant) ID for `VGUSTESTAI` |
| `AZURE_CLIENT_SECRET` | Current service-principal secret value |
| `VLMS_ENV_FILE` | Complete application `.env` content |

The supplied job does not declare `environment: DEV`. It therefore uses repository secrets and variables. If you later add a GitHub environment, review which settings are defined there: environment secrets can override repository secrets with the same names.

### Application .env handling

Paste your complete application configuration into `VLMS_ENV_FILE`, using the variable names required by your images. Example only:

```dotenv
ENVIRONMENT=production
AZURE_KV_URL=https://your-key-vault.vault.azure.net/
AZURE_CLIENT_ID=your-application-client-id
AZURE_TENANT_ID=your-directory-tenant-id
AZURE_CLIENT_SECRET='your-current-application-secret'
VERSION=v50112
VLMS_VLS_VERSION=v5.0.1.1.2
API_TOKEN='your-application-token'
CMS_TOKEN='your-cms-token'
CG_FEATURE_NAME='CONTENT GENERATION'
```

This is not a complete replacement for your actual application `.env`: retain all required URLs, ports, feature settings, worker settings, Redis configuration, and other values.

The workflow transfers the secret over SSH stdin, writes a temporary file, sets mode `600`, and atomically places it at:

```text
/home/vgadmin/VLMS/v5.0.1.1.2/.env
```

The provided Compose files use `env_file: ./.env`. Do not `source .env` in a shell: let Compose parse it. Quote literal values appropriately, especially values containing dollar signs or spaces. Do not print the file or expanded Compose configuration in shared logs.

## 8. GitHub Nginx variable

Open **Settings → Secrets and variables → Actions → Variables → New repository variable**.

- **Name:** `NGINX_CONF_CONTENT`
- **Value:** exactly the following five location blocks.

```nginx
location /v5.0.1.1.2/AIExecution/ {
    proxy_pass http://ai_exe_sad-v5.0.1.1.2:4010/;
    include /etc/nginx/proxy-params.conf;
}

location /v5.0.1.1.2/AIExecution/analyze-image {
    proxy_pass http://ai_exe_sad-v5.0.1.1.2:4010/analyze-image;
    include /etc/nginx/proxy-params.conf;
    proxy_connect_timeout 300s;
}

location /v5.0.1.1.2/AIContentGeneration/ {
    proxy_pass http://ai_content_generation-v5.0.1.1.2:4000/;
    include /etc/nginx/proxy-params.conf;
}

location /v5.0.1.1.2/AISmartGapAssessor/ {
    proxy_pass http://ai_sga-v5.0.1.1.2:8080/api/;
    include /etc/nginx/proxy-params.conf;
}

location /v5.0.1.1.2/AISmartAuthor/ {
    proxy_pass http://ai_smart_generation-v5.0.1.1.2:8000/;
    proxy_read_timeout 300s;
    include /etc/nginx/proxy-params.conf;
}
```

Do not include Markdown fences, a `server {}` wrapper, a full configuration, or `/v50112/` paths in the variable value. `VERSION=v50112` in `.env` and the Compose project names can remain unchanged; the externally configured location prefix is `/v5.0.1.1.2/`.

### How the merge works

The workflow stages the fragment on the VM and builds a merged candidate from the existing Nginx configuration. It inserts missing locations or updates matching release locations, preserving unrelated server settings, routes, certificates, and the HTTP redirect block. Repeated runs do not append duplicate locations.

The current merger expects exactly one HTTPS server block listening on port 443 and exactly the five release locations above. It also supports the legacy release marker comments created by earlier workflow versions. Duplicate locations, ambiguous markers, or unsupported fragments cause failure before the candidate is applied.

The workflow extracts DNS from `server_name` in the merged candidate. It expects one distinct ordinary hostname, ignoring `_`. Multiple application domains require a deliberate workflow change.

Before applying the merge, it saves a timestamped backup. It writes the merged result into the existing host file in place because that individual file is bind-mounted into the Nginx container. This updates release entries without discarding the rest of the configuration.

## 9. ai-start.sh

Commit the following error-handling version as `deployments/v5.0.1.1.2/ai-start.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

test -s .env || {
    echo "ERROR: .env is missing or empty."
    exit 1
}

deploy() {
    local project="$1"
    local compose_file="$2"

    echo "Validating: $compose_file"
    docker compose --env-file .env \
        -p "$project" -f "$compose_file" config --quiet

    echo "Pulling images: $compose_file"
    docker compose --env-file .env \
        -p "$project" -f "$compose_file" pull

    echo "Starting: $compose_file"
    docker compose --env-file .env \
        -p "$project" -f "$compose_file" up -d
}

deploy ai-service-cg-v50112 content-generation-docker-compose.yaml
deploy ai-service-ea-v50112 execution-assisstant-docker-compose.yaml
deploy ai-service-ing-v50112 ingestion-docker-compose.yaml
deploy ai-service-sga-v50112 sga-docker-compose.yaml
deploy ai-service-sg-v50112 smart-generation-docker-compose.yaml

echo "All five deployment commands completed successfully."
```

The workflow validates the five Compose files before calling this script and makes `.sh` files executable. The script's own `set -euo pipefail` remains necessary: a parent shell's error handling does not reliably make an independent script fail on its first internal error.

`up -d` returning successfully means Compose started the services; application readiness is checked later. No image build is performed. The workflow does not independently guarantee image refresh if you keep an older start script without the explicit `pull` commands.

### Expected containers

| Compose file | Container names |
|---|---|
| Content generation | `ai_content_generation-v5.0.1.1.2` |
| Execution assistant | `ai_exe_sad-v5.0.1.1.2` |
| Ingestion | `ai_ingestion-v5.0.1.1.2` |
| SGA | `ai_sga-v5.0.1.1.2`, `ai_sga-celery-v5.0.1.1.2` |
| Smart generation | `ai_smart_generation-v5.0.1.1.2`, `ai_smart_generation_worker-v5.0.1.1.2` |

All five supplied Compose files use external network `ai_net`. Validate that application listening ports agree with Nginx; the SGA upstream currently targets port 8080 and `/api/`. A differently configured SGA application port must be resolved in the application/route configuration.

DronaAKS is not included in this workflow. Its Compose definition and role as a release-specific or shared service must be established before adding it. The existing document processor, Nginx, logging, and monitoring containers are not created by these five deployment files.

## 10. Deployment order

1. Check out the selected Git commit.
2. Validate repository filenames and basic SSH/ACR settings.
3. Configure the SSH key, verified known_hosts entry, and `vlms-target` alias.
4. Verify server commands, Docker access, network, data directory, existing Nginx, and configuration-file permissions.
5. Authenticate Azure CLI on Ubuntu using `VGUSTESTAI`.
6. Copy repository deployment files with `rsync`, excluding `.env` files.
7. Generate the server `.env` from `VLMS_ENV_FILE`.
8. Transfer the five location blocks from `NGINX_CONF_CONTENT`.
9. Acquire a remote deployment lock, log Docker into ACR, validate Compose files, and execute `ai-start.sh`.
10. Merge the release locations into a candidate Nginx configuration and extract its DNS hostname.
11. Back up the existing configuration and apply the merged candidate in place.
12. Run `docker exec ai_nginx nginx -t`.
13. Restart `ai_nginx` and verify it is running and passes configuration validation.
14. Wait **60 seconds**.
15. Run the four HTTPS readiness checks with `curl`.
16. Remove temporary SSH files from the GitHub runner.

The workflow's concurrency group serializes jobs in that group instead of cancelling a running deployment. The remote `flock` covers the deploy/merge/check phase; copying files and secrets occurs earlier, so separate workflows targeting the same release directory must also be coordinated.

## 11. Readiness verification

The application gate is based on HTTP responses, not Docker `.State.Health`. An image-defined `unhealthy` status alone no longer fails this gate.

DNS is obtained from Nginx. With the current server name, requests are:

```text
https://VGUSTESTSVRAI01.valgenesis.net/v5.0.1.1.2/AIContentGeneration/ready
https://VGUSTESTSVRAI01.valgenesis.net/v5.0.1.1.2/AISmartAuthor/ready
https://VGUSTESTSVRAI01.valgenesis.net/v5.0.1.1.2/AIExecution/ready
https://VGUSTESTSVRAI01.valgenesis.net/v5.0.1.1.2/AISmartGapAssessor/ready
```

Checks run on the Ubuntu VM over SSH. They exercise DNS/TLS and the route reached from that VM, not from the GitHub runner or every customer network.

Each URL receives up to 12 attempts, with a 5-second connection timeout, 10-second request timeout, and a 3-second pause after unsuccessful attempts. Success requires HTTP **200** for all four URLs. Redirects are not followed and do not count as ready. TLS certificate verification remains enabled. Curl/network failures are reported as HTTP `000`.

The workflow checks HTTP status only, not JSON response fields. It does not directly verify ingestion processing, Celery queue consumption, or smart-generation background-worker functionality. There is no chatbot readiness check.

Nginx must resolve upstream container names when `nginx -t` runs. The later 60-second wait cannot fix a missing upstream container or failed pre-restart validation.

## 12. Run a deployment

1. Confirm the pre-run checklist below.
2. Commit `deploy.yml`, `ai-start.sh`, and all five Compose files.
3. Open **Automations → Actions → Deploy VLMS to Azure Ubuntu**.
4. Select **Run workflow**, choose the intended branch, and start the job.
5. Follow each step's logs. A complete success includes four HTTP 200 readiness results.

After editing repository files, start a new workflow run for the new commit. Rerunning an older failed run uses that run's commit and does not pick up newly committed workflow code.

### Pre-run checklist

- [ ] SSH endpoint and port match the target VM.
- [ ] Network rules permit the current runner to reach SSH.
- [ ] Deployment key authenticates as `vgadmin`.
- [ ] `SSH_KNOWN_HOSTS` matches the server's verified host key.
- [ ] All nine repository secrets and `NGINX_CONF_CONTENT` are configured.
- [ ] `VGUSTESTAI` has ACR pull access and its secret is valid.
- [ ] `ai-start.sh` uses the error-handling version above.
- [ ] Five exact Compose filenames exist in the source directory.
- [ ] `/AI-DATA` is backed by the intended persistent storage.
- [ ] `ai_net` exists; Nginx and application containers use it.
- [ ] Current Nginx configuration is valid and writable, and its parent directory permits backups.
- [ ] New location prefixes match the four readiness URLs.
- [ ] Required application services, data stores, and feature settings are available.

## 13. Failure handling and rollback

The workflow backs up Nginx to a file resembling:

```text
/home/vgadmin/Common-AI/nginx/nginx.conf.backup.YYYYMMDDTHHMMSSZ.PID
```

If an error occurs after Nginx configuration application, the error handler attempts to restore the backup in place and restart `ai_nginx`. A failure before application leaves the previous Nginx file unchanged. Recovery restart requests are logged; inspect Nginx afterward if recovery itself reports an error.

**This is Nginx configuration recovery, not a full deployment rollback.** Application containers, images, `.env`, and application data are not restored automatically. If a later Compose command fails, earlier projects may already be updated. Backups remain on the VM; the workflow has no backup retention cleanup.

For an application rollback, use the approved previous image tags and configuration and redeploy deliberately. Avoid removing data volumes or pruning images needed for recovery.

To restore a chosen Nginx backup manually, first verify it is the intended backup. Then, replacing the placeholder filename:

```bash
cat /home/vgadmin/Common-AI/nginx/nginx.conf.backup.CHOSEN_BACKUP \
  > /home/vgadmin/Common-AI/nginx/nginx.conf

docker exec ai_nginx nginx -t && docker restart ai_nginx
```

## 14. Troubleshooting

| Error | Meaning / next action |
|---|---|
| `Missing: .../ai-start.sh` | Repository filename/path or selected commit is wrong. The script must be committed as `ai-start.sh`. |
| SSH `Connection timed out` | Check public endpoint, runner IP permission, NSGs, host firewall, SSH listener, and private-network reachability. |
| `No ED25519 host key is known` | Fix the host/port entry in the secret scope actually used by the job. Do not disable strict checking. |
| SSH `Permission denied (publickey)` | Verify deployment private/public key pairing, `vgadmin` authorized_keys, ownership, and permissions. |
| Docker socket `permission denied` | Fix the deployment user's Docker access and reconnect. |
| Azure login fails | Check client ID, tenant, current secret value/expiry, and outbound access. |
| ACR unauthorized | Verify registry name, applicable pull role, repository scope, and that login/pull run as the same user. |
| Fragment validation rejects Nginx variable | Paste only the five `/v5.0.1.1.2/` locations, not full server configuration or `/v50112/` locations. |
| `Expected exactly one HTTPS server block` | Current config layout is unsupported/ambiguous; select the intended server in a workflow update. |
| `host not found in upstream` | Named API container is missing, stopped/restarting, or not on Nginx's network. Investigate deployment before changing DNS settings. |
| HTTP 404 | Confirm dotted release prefix and upstream readiness path. A longer sleep does not fix an incorrect route. |
| HTTP 502/504 | Check upstream process, listening port, network reachability, dependencies, and timeouts. |
| HTTP 401/403 | Determine whether readiness requires authentication or is blocked by an access policy. |
| HTTP 000 | Check DNS resolution, TLS trust, connection refusal, routing, and curl timeouts. |
| Docker status `unhealthy` | Not the current application gate. Investigate the image's health check separately; a worker may inherit an API-specific health check. |

### Inspect SGA health-check failures separately

```bash
docker inspect --format '{{json .Config.Healthcheck}}' ai_sga-v5.0.1.1.2
docker inspect --format '{{json .State.Health}}' ai_sga-v5.0.1.1.2
docker logs --tail 100 ai_sga-v5.0.1.1.2

docker inspect --format '{{json .Config.Healthcheck}}' ai_sga-celery-v5.0.1.1.2
docker inspect --format '{{json .State.Health}}' ai_sga-celery-v5.0.1.1.2
docker logs --tail 100 ai_sga-celery-v5.0.1.1.2
```

### Test HTTPS readiness manually

```bash
curl --show-error --include --connect-timeout 5 --max-time 10 \
  https://VGUSTESTSVRAI01.valgenesis.net/v5.0.1.1.2/AIContentGeneration/ready
```

Use the other three paths from section 11 as needed. Do not bypass TLS verification merely to make deployment pass.

## 15. Updating a future release

The current workflow is intentionally scoped to v5.0.1.1.2. Updating only `.env` is insufficient for another release.

Review all of the following together:

- Repository `SOURCE_DIR`, remote `DEPLOY_DIR`, and hardcoded paths in SSH/Python steps.
- Expected file list and `ai-start.sh`.
- Compose project names, image tags, and container names.
- Nginx variable content and the merger's accepted/expected location paths.
- Readiness endpoint paths.
- Concurrency group and remote lock scope.
- Application `.env`, service-principal credentials, dependency settings, and persistent storage paths.

Keep shared existing routes and services intact unless the release explicitly retires them. Test the new release's workflow before treating it as ready for another environment.

## 16. Validation scope and references

The workflow's YAML and Bash syntax, embedded merge logic, dotted-prefix acceptance, repeated-run behavior, and preservation of existing test configuration were checked locally during preparation. No successful end-to-end deployment on this VM is established by those checks. Server dependencies, container startup, actual TLS trust, and readiness responses require a successful live run.

Official references:

- [ACR service-principal authentication](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-auth-service-principal)
- [ACR authentication and permission troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-container-registry/authentication-required)
- [GitHub-hosted runner networking](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Docker Engine installation on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Compose plugin installation](https://docs.docker.com/compose/install/linux/)
- [Azure CLI installation on Linux](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux)
- [Nginx command-line validation and control](https://nginx.org/en/docs/switches.html)
