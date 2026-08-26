# Channel Name Restrictions

Mattermost plugin that reserves configured channel name prefixes for admins.

Behavior:

- Watches newly created public and private channels
- Matches configured prefixes against both the channel display name and the URL handle
- Allows System Admins and Team Admins to create restricted channels
- Deletes restricted channels created by non-admins and sends an ephemeral explanation to the creator

Config:

- `RestrictedPrefixes`: comma, semicolon, or newline-separated prefixes
- `RejectionMessage`: optional custom message shown to blocked users

Notes:

- The Mattermost server plugin API exposes `ChannelHasBeenCreated`, not a pre-create rejection hook
- Because of that API limitation, the plugin enforces the policy by deleting unauthorized channels immediately after they are created

Local build:

- `cd server && go build ./...`
