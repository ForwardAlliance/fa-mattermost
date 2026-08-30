#!/bin/sh
set -eu

target_file="${1:?target html path is required}"
stylesheet_href="${2:?stylesheet href is required}"
script_src="${3:?script src is required}"
link_tag="<link rel=\"stylesheet\" href=\"${stylesheet_href}\">"
script_tag="<script defer src=\"${script_src}\"></script>"

inject_before_head_close() {
  tag="$1"

  if grep -Fq "$tag" "$target_file"; then
    return 0
  fi

  tmp_file="${target_file}.tmp"

  sed "s#</head>#${tag}</head>#" "$target_file" > "$tmp_file"

  if cmp -s "$target_file" "$tmp_file"; then
    rm -f "$tmp_file"
    echo "failed to inject tag into $target_file: $tag" >&2
    exit 1
  fi

  mv "$tmp_file" "$target_file"
}

inject_before_head_close "$link_tag"
inject_before_head_close "$script_tag"
