#!/usr/bin/env bash
# Publish mattermost/ to the public AGPL mirror.
#
# AGPL v3.0 section 13 requires the Corresponding Source of the modified server
# to be available to everyone who uses it over the network. The deployed binary
# is reproduced from the pinned upstream revision plus the patch scripts and
# Dockerfile here, so mirroring this directory is what satisfies that.
#
# Usage:
#   scripts/sync-public-mirror.sh --repo git@github.com:ORG/REPO.git [--dry-run]
#
# Files come from `git archive`, so only committed, non-ignored files are ever
# published: mattermost/.env is gitignored and cannot reach the mirror even if
# it exists in the working tree. The secret scan is a second line of defence
# against something sensitive having been committed to the monorepo by mistake.

set -euo pipefail

repo=''
dry_run=false
source_ref='HEAD'

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    --ref) source_ref="${2:?--ref needs a value}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$repo" ] && [ "$dry_run" = false ]; then
  echo "sync-public-mirror: --repo is required (or use --dry-run)" >&2
  exit 2
fi

monorepo_root="$(git rev-parse --show-toplevel)"
cd "$monorepo_root"

source_sha="$(git rev-parse --short "$source_ref")"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# ---------------------------------------------------------------------------
# 1. Export tracked files only
# ---------------------------------------------------------------------------

git archive "$source_ref" mattermost | tar -x -C "$staging"
export_dir="$staging/mattermost"

if [ ! -d "$export_dir" ]; then
  echo "sync-public-mirror: nothing exported from $source_ref" >&2
  exit 1
fi

file_count="$(find "$export_dir" -type f | wc -l | tr -d ' ')"
echo "Exported $file_count files from $source_ref ($source_sha)"

for required in LICENSE NOTICE Dockerfile; do
  if [ ! -f "$export_dir/$required" ]; then
    echo "sync-public-mirror: $required is missing from the export." >&2
    echo "  It must be committed before publishing: AGPL section 13 wants the" >&2
    echo "  license and the modification notice to travel with the source." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 2. Refuse to publish anything that looks like a live credential
# ---------------------------------------------------------------------------

# Values that are obviously stand-ins in the .example files. Anything matching
# these is not treated as a finding.
placeholder='REPLACE_WITH|replace-me|your-password|example\.com|changeme|PROJECT_ID|REGION:INSTANCE|CHANGE_ME|<[A-Z_]+>'

# A setting whose name merely contains a secret-ish word — CORSALLOWCREDENTIALS,
# ENABLEUSERACCESSTOKENS — carries a switch, not a credential. The local dev
# compose file also uses the literal "password" for its throwaway PostgreSQL,
# which is by definition not worth protecting.
non_secret_value="[:=][[:space:]]*'?(true|false|[0-9]+|password|postgres|mattermost)'?[[:space:]]*$"

findings=0
report() {
  findings=$((findings + 1))
  echo "  [$1] $2" >&2
}

echo "Scanning for credentials..."

# High-confidence token shapes, regardless of surrounding context.
while IFS= read -r hit; do
  report "token" "$hit"
done < <(
  grep -rnIE \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e 'AIza[0-9A-Za-z_-]{35}' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'gh[pousr]_[A-Za-z0-9]{36,}' \
    -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    -e 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.' \
    "$export_dir" 2>/dev/null | grep -vE "$placeholder" || true
)

# Secret-shaped assignments carrying a real-looking value. A ${VAR} reference or
# a known placeholder is fine; a literal is not.
while IFS= read -r hit; do
  report "assignment" "$hit"
done < <(
  grep -rnIE '(PASSWORD|SECRET|TOKEN|PRIVATE_KEY|ACCESSKEY|ACCESS_KEY|APIKEY|API_KEY|CREDENTIAL)[A-Z_]*[:=][[:space:]]*[^[:space:]$]' \
    "$export_dir" 2>/dev/null \
    | grep -vE "$placeholder" \
    | grep -vE '[:=][[:space:]]*(\$\{|""|'"''"'|$)' \
    | grep -vE '[:=][[:space:]]*[a-z_]+\.sh' \
    | grep -vE "$non_secret_value" \
    || true
)

# A .env that is not an example must never appear.
while IFS= read -r hit; do
  report "env-file" "${hit#$staging/}"
done < <(find "$export_dir" -name '.env' -o -name '.env.*' ! -name '*.example' | sort)

if [ "$findings" -gt 0 ]; then
  echo >&2
  echo "sync-public-mirror: $findings possible credential(s) found; nothing was published." >&2
  echo "Remove them from the monorepo (and rotate them — they are in git history)," >&2
  echo "or extend the placeholder allowlist in this script if they are false positives." >&2
  exit 1
fi

echo "  clean"

# ---------------------------------------------------------------------------
# 3. Point the source offer at the mirror
# ---------------------------------------------------------------------------

if [ -n "$repo" ]; then
  browse_url="$(printf '%s' "$repo" \
    | sed -e 's#^git@\([^:]*\):#https://\1/#' -e 's#\.git$##')"
  tmp_notice="$export_dir/NOTICE.tmp"
  sed "s#<PUBLIC_REPO_URL>#${browse_url}#" "$export_dir/NOTICE" > "$tmp_notice"
  mv "$tmp_notice" "$export_dir/NOTICE"

  if grep -q '<PUBLIC_REPO_URL>' "$export_dir/NOTICE"; then
    echo "sync-public-mirror: NOTICE still has an unresolved placeholder" >&2
    exit 1
  fi
fi

if [ "$dry_run" = true ]; then
  echo
  echo "Dry run. Would publish:"
  (cd "$export_dir" && find . -type f | sed 's#^\./#  #' | sort)
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Mirror and push
# ---------------------------------------------------------------------------

mirror="$staging/mirror"
git clone --depth 1 "$repo" "$mirror" 2>/dev/null || {
  echo "Clone failed; initialising a new repository."
  mkdir -p "$mirror"
  git -C "$mirror" init -q
  git -C "$mirror" remote add origin "$repo"
}

# Everything tracked in the mirror is replaced, so files deleted in the monorepo
# also disappear here. .git is preserved.
find "$mirror" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
(cd "$export_dir" && tar -c .) | tar -x -C "$mirror"

git -C "$mirror" add -A

if git -C "$mirror" diff --cached --quiet; then
  echo "Mirror already matches $source_sha; nothing to push."
  exit 0
fi

git -C "$mirror" commit -q -m "Sync from monorepo $source_sha

Corresponding Source for the modified Mattermost server, published under
AGPL v3.0 section 13. See NOTICE for the upstream revision and the list of
modifications."

branch="$(git -C "$mirror" symbolic-ref --short HEAD)"
git -C "$mirror" push -u origin "$branch"

echo "Published $source_sha to $repo ($branch)"
