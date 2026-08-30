# Deploy Mattermost

This guide documents the production deployment flow for a brand new Mattermost instance in this repo.

The deployment model is:

- Cloud Build builds the Mattermost image and pushes it to Artifact Registry
- Cloud Build copies `mattermost/` to the VM at `/srv/mattermost`
- Cloud Build reads the production `.env` content from Secret Manager and appends the image tag it just pushed
- The VM runs `docker compose -f docker-compose.yml -f docker-compose.prod.yml pull mattermost` then `up -d`
- Mattermost connects to Cloud SQL through the `cloud-sql-proxy` sidecar
- Cloudflare Tunnel publishes the service externally

Building the image in Cloud Build keeps the work off the serving host, and gives
every deploy an immutable image tag to roll back to. This matters more now that
the Dockerfile compiles the Mattermost server from source rather than using the
published binary as-is.

## Prerequisites

You need these resources before the first deploy:

- A GCP project
- An Artifact Registry Docker repository to hold the Mattermost image
- A Compute Engine VM reachable through IAP
- A Cloud SQL for PostgreSQL instance with private IP enabled
- A Cloudflare Tunnel and tunnel token for the Mattermost hostname
- A Secret Manager secret containing the production `.env`

You also need these values:

- `PROJECT_ID`: GCP project ID
- `ZONE`: VM zone
- `VM_NAME`: Compute Engine VM name
- `REMOTE_DIR`: deploy directory on the VM, usually `/srv/mattermost`
- `ENV_SECRET`: Secret Manager secret name containing the Mattermost `.env`
- `SITE_URL`: public Mattermost URL, for example `https://chat.example.com`
- `WEB_ORIGINS`: space-separated web origins allowed to embed Mattermost and call its API, for example `https://manual.forward.org.tw` (prod) or `https://manual.icanhelp.tw` (preview)
- `INSTANCE_CONNECTION_NAME`: Cloud SQL connection name in the form `project:region:instance`

## 1. Create Cloud SQL

Create a PostgreSQL instance, database, and user.

Example:

```bash
gcloud sql instances create mattermost-prod \
  --project=PROJECT_ID

gcloud sql databases create mattermost \
  --project=PROJECT_ID \
  --instance=mattermost-prod

gcloud sql users create mattermost \
  --project=PROJECT_ID \
  --instance=mattermost-prod \
  --password='REPLACE_WITH_STRONG_PASSWORD'

gcloud sql instances describe mattermost-prod \
  --project=PROJECT_ID \
  --format='value(connectionName)'
```

Requirements:

- The instance must be reachable from the VM over private networking
- The VM service account must have `roles/cloudsql.client`
- The VM must use access scopes that include `cloud-platform` or Cloud SQL access will fail at runtime

## 1b. Pick The Artifact Registry Repository

This repo already publishes app images to the shared `forwardalliance` repository
in `asia-east1`, and Mattermost uses it too. The `_IMAGE` substitution defaults to
`asia-east1-docker.pkg.dev/core-services-470310/forwardalliance/mattermost`.

Only if you are standing up a new project:

```bash
gcloud artifacts repositories create forwardalliance \
  --project=PROJECT_ID \
  --repository-format=docker \
  --location=asia-east1
```

## 2. Create The VM

Create a Linux VM in the same VPC or peered network as the Cloud SQL instance.

Requirements on the VM:

- OS Login enabled
- IAP SSH access enabled
- Docker Engine installed
- Docker Compose plugin installed
- The login user used by Cloud Build can run `sudo`
- `gcloud` on `PATH`, which the deploy step uses to mint a registry token

The VM needs no pre-configured registry credentials. The deploy step runs
`docker login` against Artifact Registry on every deploy, using a short-lived
token from the VM's own service account. A one-time `gcloud auth configure-docker`
would not work here: under OS Login the operator running setup and the Cloud Build
service account running the deploy are different Linux users, and the deploy runs
docker under `sudo`, so it reads root's credentials rather than either of theirs.

Example package install on Debian or Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
```

Create the shared deploy directory once:

```bash
sudo mkdir -p /srv/mattermost
```

## 3. Grant IAM

Cloud Build runs as the Compute Engine default service account, which is also the
service account attached to the VM. One principal therefore covers both sides, and
`roles/artifactregistry.writer` on it grants the push and the pull.

That service account needs these roles, matching `cloudbuild.mattermost.yaml`:

- `roles/compute.viewer`
- `roles/compute.osAdminLogin`
- `roles/iap.tunnelResourceAccessor`
- `roles/secretmanager.secretAccessor`
- `roles/artifactregistry.writer`
- `roles/cloudsql.client`

If the VM does not have broad access scopes, recreate it or update it so Cloud SQL Proxy can mint credentials successfully.

## 4. Create The Cloudflare Tunnel

Create a Cloudflare Tunnel for the public hostname and route it to the Mattermost container.

Requirements:

- The hostname in Cloudflare must match `MM_SITE_URL`
- The tunnel token must allow `cloudflared` to start with `tunnel --no-autoupdate run`

This repo does not manage the tunnel itself. It only runs `cloudflared` with the token you provide.

## 5. Create The Production Env Secret

Create a Secret Manager secret that contains the full production `.env` file.

Start from `mattermost/.env.prod.example`:

```dotenv
MM_DATASOURCE=postgres://mattermost:REPLACE_WITH_PASSWORD@/mattermost?host=/cloudsql/PROJECT_ID:REGION:INSTANCE
MM_SITE_URL=https://chat.example.com
MM_WEB_ORIGINS=https://manual.example.com
MM_FILESETTINGS_DRIVERNAME=amazons3
MM_FILESETTINGS_AMAZONS3ACCESSKEYID=REPLACE_WITH_GCS_HMAC_ACCESS_KEY
MM_FILESETTINGS_AMAZONS3SECRETACCESSKEY=REPLACE_WITH_GCS_HMAC_SECRET
MM_FILESETTINGS_AMAZONS3BUCKET=REPLACE_WITH_GCS_BUCKET
MM_FILESETTINGS_AMAZONS3PATHPREFIX=
MM_FILESETTINGS_AMAZONS3REGION=
MM_FILESETTINGS_AMAZONS3ENDPOINT=storage.googleapis.com
MM_FILESETTINGS_AMAZONS3SSL=true
MM_FILESETTINGS_AMAZONS3SIGNV2=false
CLOUDSQL_INSTANCE_CONNECTION_NAME=PROJECT_ID:REGION:INSTANCE
CLOUDFLARE_TUNNEL_TOKEN=REPLACE_WITH_TUNNEL_TOKEN
```

For GCS-backed object storage:

- Create HMAC credentials for a service account that can read and write the bucket.
- A GCE VM attached service account is not enough by itself here; Mattermost's S3 client expects S3-style credentials rather than GCP metadata-based auth.
- Keep `MM_FILESETTINGS_AMAZONS3ENDPOINT=storage.googleapis.com` and `MM_FILESETTINGS_AMAZONS3SSL=true`.
- Leave `MM_FILESETTINGS_AMAZONS3REGION` empty unless your setup needs a specific value.

For the first production bootstrap, also add these temporary lines so the first user can self-register:

```dotenv
MM_ENABLE_USER_CREATION=true
MM_ENABLE_SIGNUP_WITH_EMAIL=true
```

Create the secret and add the first version:

```bash
gcloud secrets create mattermost-prod-env \
  --project=PROJECT_ID \
  --replication-policy=automatic
```

Then upload the filled `.env` file as a secret version.

## 6. Run The First Deploy

Run Cloud Build from the repo root:

```bash
gcloud builds submit \
  --project=PROJECT_ID \
  --config=cloudbuild.mattermost.yaml \
  --substitutions=_PROJECT_ID=PROJECT_ID,_GCP_ZONE=ZONE,_VM_NAME=VM_NAME,_REMOTE_DIR=/srv/mattermost,_ENV_SECRET=mattermost-prod-env
```

What this does:

- Builds the Mattermost image and pushes it to `_IMAGE:$BUILD_ID`, including the server binary rebuilt from AGPLv3 source with the activated-user cap raised, custom plugins under `mattermost/plugins/`, the email-subject i18n patch used for Mandrill rejection rules, the CSS-variable theme override, and the global announcement-bar CSS override
- Copies `mattermost/` to `/srv/mattermost` on the VM
- Writes `/srv/mattermost/.env` from Secret Manager, appending `MATTERMOST_IMAGE` for the tag it just pushed
- Pulls that image on the VM and starts the production stack with Mattermost, Cloud SQL Proxy, and Cloudflare Tunnel

## 7. Create The First Admin

Open `MM_SITE_URL` after the deploy finishes.

On a fresh Mattermost database:

- The first user created becomes system admin
- With the temporary signup env vars enabled, create the first admin user through the UI

After the admin account exists:

1. Remove `MM_ENABLE_USER_CREATION=true` from the secret content
2. Remove `MM_ENABLE_SIGNUP_WITH_EMAIL=true` from the secret content
3. Add a new secret version
4. Run the same Cloud Build deploy command again

That returns the server to closed signup mode.

## 8. Verify The Deployment

Check container state on the VM:

```bash
gcloud compute ssh VM_NAME \
  --project=PROJECT_ID \
  --zone=ZONE \
  --tunnel-through-iap \
  --command='cd /srv/mattermost && sudo docker compose -f docker-compose.yml -f docker-compose.prod.yml ps'
```

Check logs if needed:

```bash
gcloud compute ssh VM_NAME \
  --project=PROJECT_ID \
  --zone=ZONE \
  --tunnel-through-iap \
  --command='cd /srv/mattermost && sudo docker compose -f docker-compose.yml -f docker-compose.prod.yml logs --tail=200 mattermost cloud-sql-proxy cloudflared'
```

Expected result:

- `mattermost` is healthy and listening on port `8065`
- `cloud-sql-proxy` is connected using the private IP path
- `cloudflared` is connected to the configured tunnel

## 9. Deploy Updates Later

For later updates, keep the same flow:

1. Change files under `mattermost/`
2. If needed, add a new version to the env secret
3. Run `gcloud builds submit` again with the same substitutions

Notes:

- The server binary is rebuilt from source on every deploy, which adds several minutes to the Cloud Build step; bump `_MATTERMOST_SOURCE_REF` together with `_MATTERMOST_VERSION` so the rebuilt server matches the webapp the base image ships
- Custom plugins are baked into the Mattermost image during deploy
- To roll back, redeploy with the `MATTERMOST_IMAGE` line pointing at an earlier `_IMAGE:BUILD_ID` tag; build tags are immutable, so an older tag is a complete rollback of the image
- Email notification subjects are rewritten during the image build from `/mattermost/i18n/*.json`, so rebuilds also pick up changes to that patch logic
- The injected `/static/overrides.css` overrides Mattermost theme CSS variables on `html` with `!important`, so the branded colors win over runtime inline theme variables
- The webapp root document is patched during the image build to load `/static/overrides.css`, so rebuilds also pick up UI overrides such as hidden announcement bars
- Plugin directories are not persisted as Docker volumes, so a rebuild picks up plugin changes cleanly
- The deploy replaces the workspace under `/srv/mattermost`, so treat that directory as generated deployment state, not hand-managed config

## Common Failures

`cloud-sql-proxy` fails with `ACCESS_TOKEN_SCOPE_INSUFFICIENT`:

- The VM service account or VM access scopes are missing Cloud SQL access

`cloud-sql-proxy` fails with `instance does not have IP of type "PUBLIC"`:

- The instance is private-only and the proxy must keep using `--private-ip`

The site comes up but no one can sign in on first boot:

- Signup is still disabled in the env secret
- Add the two temporary signup variables, deploy once, create the first admin, then remove them and deploy again
