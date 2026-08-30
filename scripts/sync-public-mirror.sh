#!/usr/bin/env bash
# Publish mattermost/ to the public AGPL mirror.
#
# AGPL v3.0 section 13 requires the Corresponding Source of the modified server
# to be available to everyone who uses it over the network. The deployed binary
# is reproduced from the pinned upstream revision plus the patch scripts and
# Dockerfile here, so mirroring this directory is what satisfies that.
#
# Usage:
#   scripts/sync-public-mirror.sh --repo https://github.com/ORG/REPO [--dry-run]
#   scripts/sync-public-mirror.sh --repo git@github.com:ORG/REPO.git [--dry-run]
#
# --repo must not carry credentials. Either authenticate over SSH -- what the
# deploy does, with a repo-scoped deploy key supplied through GIT_SSH_COMMAND
# -- or set MIRROR_TOKEN (and optionally MIRROR_USERNAME), which is handed to
# git through GIT_ASKPASS. Both keep the credential out of the URL, out of
# `ps`, out of push output, and out of anything derived from the URL such as
# the NOTICE below.
#
# Files come from `git archive`, so only committed, non-ignored files are ever
# published: mattermost/.env is gitignored and cannot reach the mirror even if
# it exists in the working tree. The secret scan is a second line of defence
# against something sensitive having been committed to the monorepo by mistake.

set -euo pipefail

repo=''
dry_run=false
source_ref='HEAD'
target_branch=''

# `${2:?...}` aborts on an empty value as well as a missing one, which turns an
# unset CI substitution into a cryptic bash error. The count is checked instead
# so a genuinely absent argument is still rejected, with our own message.
need_value() {
  if [ "$2" -lt 2 ]; then
    echo "sync-public-mirror: $1 needs a value" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$1" "$#"; repo="$2"; shift 2 ;;
    --ref) need_value "$1" "$#"; source_ref="$2"; shift 2 ;;
    --branch) need_value "$1" "$#"; target_branch="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# An empty --ref means the caller had no commit to name (a manually started
# build has no COMMIT_SHA); publishing the checkout as it stands is right.
[ -n "$source_ref" ] || source_ref='HEAD'

if [ -z "$repo" ] && [ "$dry_run" = false ]; then
  echo "sync-public-mirror: --repo is required (or use --dry-run)" >&2
  exit 2
fi

case "$repo" in
  *://*@*|git@*:*@*)
    echo "sync-public-mirror: --repo must not embed credentials." >&2
    echo "  Pass the plain URL and put the token in MIRROR_TOKEN; a URL with" >&2
    echo "  userinfo leaks into push output and into the published NOTICE." >&2
    exit 2 ;;
esac

monorepo_root="$(git rev-parse --show-toplevel)"
cd "$monorepo_root"

source_sha="$(git rev-parse --short "$source_ref")"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

export GIT_TERMINAL_PROMPT=0
if [ -n "${MIRROR_TOKEN:-}" ]; then
  export MIRROR_TOKEN
  export MIRROR_USERNAME="${MIRROR_USERNAME:-x-access-token}"
  askpass="$staging/askpass"
  cat > "$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "$MIRROR_USERNAME" ;;
  Password*) printf '%s\n' "$MIRROR_TOKEN" ;;
esac
ASKPASS
  chmod 700 "$askpass"
  export GIT_ASKPASS="$askpass"
fi

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
# 2. Point the source offer at the mirror
#
# Rewriting the NOTICE before the scan, not after it, keeps the scan the last
# thing that touches the tree: whatever is published is exactly what was
# scanned.
# ---------------------------------------------------------------------------

if [ -n "$repo" ]; then
  browse_url="$(printf '%s' "$repo" \
    | sed -e 's#^git@\([^:]*\):#https://\1/#' \
          -e 's#^ssh://#https://#' \
          -e 's#://[^/@]*@#://#' \
          -e 's#\.git$##')"
  tmp_notice="$export_dir/NOTICE.tmp"
  sed "s#<PUBLIC_REPO_URL>#${browse_url}#" "$export_dir/NOTICE" > "$tmp_notice"
  mv "$tmp_notice" "$export_dir/NOTICE"

  if grep -q '<PUBLIC_REPO_URL>' "$export_dir/NOTICE"; then
    echo "sync-public-mirror: NOTICE still has an unresolved placeholder" >&2
    exit 1
  fi
else
  browse_url=''
fi

# ---------------------------------------------------------------------------
# 3. Refuse to publish anything that looks like a live credential
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
    -e 'github_pat_[A-Za-z0-9_]{20,}' \
    -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    -e 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.' \
    "$export_dir" 2>/dev/null | grep -vE "$placeholder" || true
)

# Any URL carrying userinfo, whatever the token looks like. The throwaway
# password of the local dev PostgreSQL is exempt for the same reason it is
# exempt above.
while IFS= read -r hit; do
  report "url-credential" "$hit"
done < <(
  grep -rnIE '[a-z][a-z0-9+.-]*://[^/[:space:]]+:[^/[:space:]]+@' \
    "$export_dir" 2>/dev/null \
    | grep -vE "$placeholder" \
    | grep -vE '://[^/[:space:]]+:(password|postgres|mattermost)@' \
    || true
)

# Secret-shaped assignments carrying a real-looking value. A ${VAR} reference or
# a known placeholder is fine; a literal is not.
#
# A shell default/error expansion — ${MIRROR_TOKEN:-} — is a reference too, but
# the pattern starts matching at the name, so the `:` of the shell operator
# reads to it as a name/value separator and `-` reads as the value. Only such an
# expansion of a secret-ish name is exempted, so an unrelated ${FOO:-} does not
# buy a line anything. The exemption is still line-wide: a line carrying both
# one of these expansions and a hardcoded secret would pass. That is why it
# names the operator instead of exempting ${...} everywhere.
while IFS= read -r hit; do
  report "assignment" "$hit"
done < <(
  grep -rnIE '(PASSWORD|SECRET|TOKEN|PRIVATE_KEY|ACCESSKEY|ACCESS_KEY|APIKEY|API_KEY|CREDENTIAL)[A-Z_]*[:=][[:space:]]*[^[:space:]$]' \
    "$export_dir" 2>/dev/null \
    | grep -vE "$placeholder" \
    | grep -vE '[:=][[:space:]]*(\$\{|""|'"''"'|$)' \
    | grep -vE '\$\{[A-Z_]*(PASSWORD|SECRET|TOKEN|PRIVATE_KEY|ACCESS_KEY|API_KEY|CREDENTIAL)[A-Z_]*:[-=?+]' \
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

# Each deployed environment runs its own commit, and section 13 is owed to the
# users of each one, so an environment gets its own branch rather than
# overwriting whatever the other deployed last.
#
# A shallow clone only fetches the branch it is told to. Cloning the default
# branch and then creating the target from it would produce a history unrelated
# to the one already on the remote, and the push would be rejected as a
# non-fast-forward, so the target branch is named up front.
if [ -n "$target_branch" ] &&
   git clone --depth 1 --branch "$target_branch" "$repo" "$mirror" 2>/dev/null; then
  echo "Updating existing branch $target_branch"
elif git clone --depth 1 "$repo" "$mirror" 2>/dev/null; then
  if [ -n "$target_branch" ]; then
    echo "Branch $target_branch does not exist yet; starting it"
    git -C "$mirror" checkout -q --orphan "$target_branch"
    git -C "$mirror" rm -rq --cached . 2>/dev/null || true
  fi
else
  echo "Clone failed; initialising a new repository."
  mkdir -p "$mirror"
  git -C "$mirror" init -q
  git -C "$mirror" remote add origin "$repo"
  [ -n "$target_branch" ] && git -C "$mirror" checkout -q -b "$target_branch"
fi

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

echo "Published $source_sha to $browse_url ($branch)"
