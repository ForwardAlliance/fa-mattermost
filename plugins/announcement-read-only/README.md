# Announcement Read Only

Mattermost plugin that keeps configured announcement channels read-only for non-admins.

Structure:

- `plugin.json`: Mattermost plugin manifest
- `server/`: Go plugin source
- `server/dist/`: local build output, ignored by git

Config:

- `ChannelName`: restricted channel slug, supports comma-separated values
- `RejectionMessage`: message shown when posting is blocked

Local build:

- `cd server && mkdir -p dist && go build -o dist/plugin-linux-amd64 .`
