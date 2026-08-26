#!/bin/sh
set -eu

target_dir="${1:-/build/i18n}"
reject_prefix='mattermost::reject '

for locale_file in "$target_dir"/*.json; do
  tmp_file="${locale_file}.tmp"

  jq --arg reject_prefix "$reject_prefix" '
    map(
      if (
        .id | type == "string" and (
          test("^api\\.templates\\..*subject$") or
          . == "api.admin.test_email.subject"
        )
      ) and
         (.translation | type == "string" and (startswith($reject_prefix) | not))
      then .translation = ($reject_prefix + .translation)
      else .
      end
    )
  ' "$locale_file" > "$tmp_file"

  mv "$tmp_file" "$locale_file"
done
