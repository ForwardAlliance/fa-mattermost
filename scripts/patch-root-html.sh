#!/bin/sh
set -eu

target_file="${1:?target html path is required}"
stylesheet_href="${2:?stylesheet href is required}"
link_tag="<link rel=\"stylesheet\" href=\"${stylesheet_href}\">"

if grep -Fq "$link_tag" "$target_file"; then
  exit 0
fi

tmp_file="${target_file}.tmp"

sed "s#</head>#${link_tag}</head>#" "$target_file" > "$tmp_file"

if cmp -s "$target_file" "$tmp_file"; then
  rm -f "$tmp_file"
  echo "failed to inject stylesheet link into $target_file" >&2
  exit 1
fi

mv "$tmp_file" "$target_file"
