#!/bin/sh
set -eu

target_file="${1:?usage: patch-user-limits.sh <limits.go> <max_users>}"
max_users="${2:?usage: patch-user-limits.sh <limits.go> <max_users>}"

case "$max_users" in
  '' | *[!0-9]*)
    echo "patch-user-limits: max_users must be a positive integer, got '${max_users}'" >&2
    exit 1
    ;;
esac

# Upstream can rename or restructure these constants between releases. A sed that
# silently matches nothing would ship a stock binary that still caps at 250, so
# every constant is asserted before and after the rewrite.
for const_name in maxUsersLimit maxUsersHardLimit; do
  if ! grep -q "^[[:space:]]*${const_name}[[:space:]]*=[[:space:]]*[0-9][0-9]*$" "$target_file"; then
    echo "patch-user-limits: ${const_name} not found in ${target_file}; upstream layout changed" >&2
    exit 1
  fi

  tmp_file="${target_file}.tmp"
  sed "s/^\([[:space:]]*${const_name}[[:space:]]*=[[:space:]]*\)[0-9][0-9]*$/\1${max_users}/" \
    "$target_file" > "$tmp_file"
  mv "$tmp_file" "$target_file"

  if ! grep -q "^[[:space:]]*${const_name}[[:space:]]*=[[:space:]]*${max_users}$" "$target_file"; then
    echo "patch-user-limits: failed to set ${const_name} to ${max_users} in ${target_file}" >&2
    exit 1
  fi
done

echo "patch-user-limits: maxUsersLimit and maxUsersHardLimit set to ${max_users}"
