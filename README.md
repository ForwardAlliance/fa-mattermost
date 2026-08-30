# Mattermost

Mattermost deployment and plugin workspace.

Files:

- `docker-compose.yml`: shared Mattermost service config
- `docker-compose.dev.yml`: local development overlay with PostgreSQL and open signup
- `docker-compose.prod.yml`: production overlay with Cloud SQL Proxy and Cloudflare Tunnel
- `plugins/`: Mattermost plugins source code

Notes:

- The server binary at `/mattermost/bin/mattermost` is rebuilt from the AGPLv3 sources at `MATTERMOST_SOURCE_REF` with `maxUsersLimit` / `maxUsersHardLimit` raised to `MM_MAX_USERS`. Upstream ships a 250 activated-user cap in `channels/app/limits.go`; the rest of the image (webapp, i18n, prepackaged plugins, `mmctl`) is still the published team-edition build.
- `MATTERMOST_SOURCE_REF` and `MATTERMOST_VERSION` must name the same exact release, and neither may be a floating tag. `MATTERMOST_VERSION: 11.3` resolves to whatever patch upstream published last, so the base image moves on its own while the pinned source does not, and the rebuilt server ends up serving a webapp from a different release.
- `docker-compose.yml` holds the full set of Mattermost settings. A value written literally there is the same in every environment; a value written as `${VAR}` is supplied per environment through the `.env` file. The prod and dev overlays only add what exists solely in that deployment mode, such as the Cloud SQL socket or the local database.
- A setting belongs in the `.env` file when any of these is true: it is a secret, it differs between environments, or it is something an operator has to change without waiting for a pull request and a deploy. Everything else is better written literally, where it is version controlled and cannot drift between environments unnoticed.
- Settings supplied through the environment are read-only in the System Console, so an admin cannot change them there. That is why the operational switches have to be environment variables rather than admin settings.
- `MM_SEND_EMAIL_NOTIFICATIONS` (default `false`) and `MM_SEND_PUSH_NOTIFICATIONS` (default `true`) are the only switches that stop Mattermost contacting users unprompted. Mattermost reaches SMTP and the push proxy itself, so no application code sits on that path. Email defaults to off so that a new or restored environment cannot mail volunteers before anyone decides it should; each environment turns it on deliberately. Both switches cover notification mail only — account mail such as password-change confirmations ignores them, and is stopped by the i18n subject prefix described below.
- `MM_FORGOT_PASSWORD_LINK` must name a host belonging to the same environment. The remaining `MM_SUPPORTSETTINGS_*` links are informational and deliberately shared. `MM_APP_DOWNLOAD_LINK` is empty by default, as described below; if it is ever given a value it has the same same-environment requirement.
- `MM_ENABLE_USER_CREATION` and `MM_ENABLE_SIGNUP_WITH_EMAIL` default to `false` and exist for the first deploy against an empty database, where the first user has to self-register to become system admin.
- The Help, Report a Problem, Download Apps and Leave Team menu entries are switched off through settings rather than hidden afterwards, because the webapp renders each one only when its setting carries a value. `MM_SUPPORTSETTINGS_HELPLINK`, `MM_SUPPORTSETTINGS_REPORTAPROBLEMLINK` and the three `MM_NATIVEAPPSETTINGS_*APPDOWNLOADLINK` settings are therefore empty by default, and `MM_TEAMSETTINGS_EXPERIMENTALPRIMARYTEAM` names the team, since the webapp shows Leave Team only while that setting differs from the current team's name. It takes the team's URL slug, not its display name, and preview and production are separate instances whose slugs need not match.
- Log Out is the exception: it has no setting, so `static/overrides.css` hides `#logout`. That is presentation only, and it applies to direct browser access as well as to the embedded client.
- The server binary is a modified AGPL work served over a network, so AGPL v3.0 section 13 requires its Corresponding Source to be published. `scripts/sync-public-mirror.sh` does that, and `cloudbuild.mattermost.yaml` runs it after each deploy so the published source cannot drift from the running one. Each environment publishes to its own branch of the mirror. See NOTICE.
- Custom plugin bundles are baked into the image under `/mattermost/forward-plugin-bundles`.
- During the image build, `/mattermost/i18n/*.json` is patched so every `api.templates.*subject` translation and `api.admin.test_email.subject` start with `mattermost::reject `.
- That prefix is intentional: Mandrill SMTP is configured with a subject rule that rejects those Mattermost notification emails before delivery.
- The same image build also patches `about.copyright` to `Powered by Mattermost` and blanks `about.teamEditiont0` (the "Team Edition" suffix), rebranding the built-in "About" popup without forking the webapp.
- During the image build, `/static/overrides.css` overrides Mattermost theme CSS variables on `html` with `!important`, so the brand colors win over the runtime inline theme variables. It also hides the About popup's logo, version-info block, open-source notice, and build hash/date footer.
- During the image build, `/mattermost/client/root.html` is patched to load `/static/overrides.css`, which hides Mattermost announcement bars globally, and `/static/overrides.js`, which rewrites the About popup's "join the community" link to point at this project's source repo instead of mattermost.com.
- `MM_PLUGINSETTINGS_DIRECTORY` points Mattermost at `/mattermost/forward-plugins` so installed custom plugins are not hidden by the base image's anonymous `/mattermost/plugins` Docker volume.
- A small bootstrap binary starts Mattermost, installs bundled custom plugins with `mmctl --local` if needed, and enables them by default.

Commands:

- Dev: `pnpm run dev:mattermost`
- Reset local state: `pnpm run clean:mattermost`
- Prod: `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build`
- Build a plugin locally: `cd plugins/announcement-read-only/server && mkdir -p dist && go build -o dist/plugin-linux-amd64 .`
- Build the channel name restrictions plugin locally: `cd plugins/channel-name-restrictions/server && mkdir -p dist && go build -o dist/plugin-linux-amd64 .`

Environment:

- Copy `.env.dev.example` or `.env.prod.example` to a local `.env` file as needed.
- Production file storage is configured through Mattermost `MM_FILESETTINGS_*` env vars; `.env.prod.example` includes GCS-friendly S3 defaults.
- In dev, create the first user in the UI. On a fresh database, that user becomes system admin.
