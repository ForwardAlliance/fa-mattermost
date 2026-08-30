#!/bin/sh
set -eu

target_dir="${1:-/build/client-i18n}"

for locale_file in "$target_dir"/*.json; do
  tmp_file="${locale_file}.tmp"

  jq '
    (if has("about.copyright") then ."about.copyright" = "Powered by Mattermost" else . end)
    | (if has("about.teamEditiont0") then ."about.teamEditiont0" = "​" else . end)
  ' "$locale_file" > "$tmp_file"

  mv "$tmp_file" "$locale_file"
done
