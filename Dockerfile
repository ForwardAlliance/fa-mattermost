ARG MATTERMOST_VERSION=11.3.3
ARG MATTERMOST_SOURCE_REF=v11.3.3
ARG MM_MAX_USERS=100000

FROM mattermost/mattermost-team-edition:${MATTERMOST_VERSION} AS mattermost-base

# The published team-edition binary hard-codes a 250 activated-user cap in
# channels/app/limits.go. AGPLv3 lets us rebuild the server without it; only the
# server binary is replaced so the webapp, i18n and prepackaged plugins stay as
# shipped. GOARCH is pinned to amd64 because the base image is amd64-only.
FROM golang:1.24-alpine AS server-builder
ARG MATTERMOST_SOURCE_REF
ARG MM_MAX_USERS
WORKDIR /build

RUN apk add --no-cache git

RUN git clone --depth 1 --branch "${MATTERMOST_SOURCE_REF}" \
  https://github.com/mattermost/mattermost.git source

COPY scripts/patch-user-limits.sh ./scripts/patch-user-limits.sh
RUN sh ./scripts/patch-user-limits.sh \
  source/server/channels/app/limits.go "${MM_MAX_USERS}"

# server/go.mod pins a published server/public version that lags the tagged tree,
# so a plain `go build` fails on symbols the tag already uses. Upstream's Makefile
# solves this with a go.work pointing at the in-tree public module (setup-go-work).
RUN cd source/server \
  && go work init \
  && go work use . \
  && go work use ./public

RUN cd source/server \
  && model_pkg=github.com/mattermost/mattermost/server/public/model \
  && build_hash=$(git -C /build/source rev-parse HEAD) \
  && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
    -ldflags "-X ${model_pkg}.BuildNumber=${MATTERMOST_SOURCE_REF#v} \
      -X '${model_pkg}.BuildDate=$(date -u)' \
      -X ${model_pkg}.BuildHash=${build_hash} \
      -X ${model_pkg}.BuildHashEnterprise=none \
      -X ${model_pkg}.BuildEnterpriseReady=false" \
    -o /mattermost-server ./cmd/mattermost

FROM golang:1.22-alpine AS builder
WORKDIR /build

COPY plugins ./plugins
COPY cmd/plugin-bootstrap ./cmd/plugin-bootstrap

RUN for plugin_dir in /build/plugins/*; do \
      [ -d "$plugin_dir/server" ] || continue; \
      cd "$plugin_dir/server"; \
      go mod download; \
      mkdir -p dist; \
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dist/plugin-linux-amd64 .; \
      CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o dist/plugin-linux-arm64 .; \
    done

RUN cd /build/cmd/plugin-bootstrap \
  && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /build/plugin-bootstrap .

FROM alpine:3.21 AS installer
WORKDIR /build

RUN apk add --no-cache jq

COPY --from=builder /build/plugins ./plugins

RUN mkdir -p /installed-plugins \
  && mkdir -p /plugin-bundles \
  && for plugin_dir in /build/plugins/*; do \
    [ -f "$plugin_dir/plugin.json" ] || continue; \
    plugin_id=$(jq -r '.id' "$plugin_dir/plugin.json"); \
    mkdir -p "/installed-plugins/$plugin_id"; \
    cp "$plugin_dir/plugin.json" "/installed-plugins/$plugin_id/"; \
    if [ -d "$plugin_dir/server/dist" ]; then \
      mkdir -p "/installed-plugins/$plugin_id/server"; \
      cp -R "$plugin_dir/server/dist" "/installed-plugins/$plugin_id/server/"; \
    fi; \
    tar -C /installed-plugins -czf "/plugin-bundles/${plugin_id}.tar.gz" "$plugin_id"; \
  done

FROM alpine:3.21 AS i18n-patcher
WORKDIR /build

RUN apk add --no-cache jq

COPY --from=mattermost-base /mattermost/i18n ./i18n
COPY --from=mattermost-base /mattermost/client/i18n ./client-i18n
COPY scripts/patch-i18n-email-subjects.sh ./scripts/patch-i18n-email-subjects.sh
COPY scripts/patch-i18n-about-text.sh ./scripts/patch-i18n-about-text.sh

RUN sh ./scripts/patch-i18n-email-subjects.sh ./i18n
RUN sh ./scripts/patch-i18n-about-text.sh ./client-i18n

FROM alpine:3.21 AS webapp-patcher
WORKDIR /build

COPY --from=mattermost-base /mattermost/client/root.html ./client/root.html
COPY scripts/patch-root-html.sh ./scripts/patch-root-html.sh
COPY static/overrides.css ./client/overrides.css
COPY static/overrides.js ./client/overrides.js

RUN css_hash=$(sha256sum ./client/overrides.css | cut -c1-12) \
  && js_hash=$(sha256sum ./client/overrides.js | cut -c1-12) \
  && sh ./scripts/patch-root-html.sh ./client/root.html \
    "/static/overrides.css?v=${css_hash}" \
    "/static/overrides.js?v=${js_hash}"

FROM mattermost/mattermost-team-edition:${MATTERMOST_VERSION}
COPY --chown=2000:2000 --from=server-builder /mattermost-server /mattermost/bin/mattermost
COPY --chown=2000:2000 --from=installer /plugin-bundles/ /mattermost/forward-plugin-bundles/
COPY --chown=2000:2000 --from=i18n-patcher /build/i18n/ /mattermost/i18n/
COPY --chown=2000:2000 --from=i18n-patcher /build/client-i18n/ /mattermost/client/i18n/
COPY --chown=2000:2000 --from=webapp-patcher /build/client/root.html /mattermost/client/root.html
COPY --chown=2000:2000 --from=webapp-patcher /build/client/overrides.css /mattermost/client/overrides.css
COPY --chown=2000:2000 --from=webapp-patcher /build/client/overrides.js /mattermost/client/overrides.js
COPY --chown=2000:2000 --from=builder /build/plugin-bootstrap /mattermost/bin/plugin-bootstrap
CMD ["/mattermost/bin/plugin-bootstrap"]
