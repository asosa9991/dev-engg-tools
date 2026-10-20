#!/usr/bin/env bash
# Create a GitHub release whose tag points at the newest commit in a date range,
# with release notes listing every commit in that range.
#
# Run it from inside the git repository you want to release.
# Requires: git, and the GitHub CLI (gh) logged in (`gh auth login`).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: release-by-date.sh --start YYYY-MM-DD --end YYYY-MM-DD --tag TAG [options]

Finds the commits on BRANCH committed between START and END (both days
inclusive, local time), tags the newest one as TAG, and creates a GitHub
release listing those commits as release notes.

Required:
  -s, --start DATE     First day of the range (YYYY-MM-DD)
  -e, --end DATE       Last day of the range (YYYY-MM-DD), inclusive
  -t, --tag TAG        Tag and release name to create, e.g. v1.4.0

Options:
  -b, --branch NAME    Branch to read history from (default: the remote's default branch)
  -r, --remote NAME    Git remote to read from (default: origin)
  -R, --repo OWNER/REPO
                       GitHub repository (default: taken from the remote's URL)
      --title TEXT     Release title (default: TAG)
      --no-merges      Leave merge commits out of the release notes
      --draft          Create the release as a draft
      --prerelease     Mark the release as a pre-release
  -n, --dry-run        Show the target commit and notes; create nothing
  -y, --yes            Skip the confirmation prompt
  -h, --help           Show this help

Example:
  release-by-date.sh --start 2026-09-01 --end 2026-09-30 --tag v1.4.0 --dry-run
EOF
}

die() { echo "error: $*" >&2; exit 1; }

# True when $1 is a real calendar date in YYYY-MM-DD form (BSD/macOS or GNU date).
valid_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  local parsed
  parsed="$(date -j -f %Y-%m-%d "$1" +%Y-%m-%d 2>/dev/null || date -d "$1" +%Y-%m-%d 2>/dev/null)" || return 1
  [[ "$parsed" == "$1" ]]
}

need_value() { [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 needs a value"; }

START="" END="" TAG="" BRANCH="" REMOTE="origin" REPO="" TITLE=""
NO_MERGES=false DRAFT=false PRERELEASE=false DRY_RUN=false ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--start)   need_value "$@"; START="$2"; shift 2 ;;
    -e|--end)     need_value "$@"; END="$2"; shift 2 ;;
    -t|--tag)     need_value "$@"; TAG="$2"; shift 2 ;;
    -b|--branch)  need_value "$@"; BRANCH="$2"; shift 2 ;;
    -r|--remote)  need_value "$@"; REMOTE="$2"; shift 2 ;;
    -R|--repo)    need_value "$@"; REPO="$2"; shift 2 ;;
    --title)      need_value "$@"; TITLE="$2"; shift 2 ;;
    --no-merges)  NO_MERGES=true; shift ;;
    --draft)      DRAFT=true; shift ;;
    --prerelease) PRERELEASE=true; shift ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -y|--yes)     ASSUME_YES=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown argument: $1" ;;
  esac
done

# --- Validate input ---------------------------------------------------------

[[ -n "$START" && -n "$END" && -n "$TAG" ]] || { usage >&2; die "--start, --end and --tag are required"; }
for d in "$START" "$END"; do
  valid_date "$d" || die "'$d' is not a valid date; use YYYY-MM-DD"
done
[[ "$START" > "$END" ]] && die "start date $START is after end date $END"
git check-ref-format "refs/tags/$TAG" || die "'$TAG' is not a valid tag name"
TITLE="${TITLE:-$TAG}"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run this from inside a git repository"
git remote get-url "$REMOTE" >/dev/null 2>&1 || die "git remote '$REMOTE' not found"

if ! $DRY_RUN; then
  command -v gh >/dev/null || die "GitHub CLI (gh) not found; install it from https://cli.github.com"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in; run 'gh auth login'"
fi

if [[ -z "$REPO" ]]; then
  url="$(git remote get-url "$REMOTE")"
  REPO="$(printf '%s\n' "$url" | sed -E 's#^(https?://|ssh://)?([^@/]+@)?github\.com[:/]##; s#\.git$##; s#/$##')"
  [[ "$REPO" =~ ^[^/:]+/[^/:]+$ ]] || die "could not read OWNER/REPO from remote URL '$url'; pass --repo"
fi

# --- Find the commits ---------------------------------------------------------

echo "Fetching $REMOTE..."
git fetch --quiet --tags "$REMOTE"

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)"
  BRANCH="${BRANCH#"$REMOTE/"}"
  if [[ -z "$BRANCH" ]]; then
    for candidate in main master; do
      if git rev-parse --verify --quiet "refs/remotes/$REMOTE/$candidate" >/dev/null; then
        BRANCH="$candidate"
        break
      fi
    done
  fi
  [[ -n "$BRANCH" ]] || die "could not work out the default branch of '$REMOTE'; pass --branch"
fi

REF="$REMOTE/$BRANCH"
git rev-parse --verify --quiet "$REF^{commit}" >/dev/null || die "branch '$REF' not found"

log_args=("$REF" --since="$START 00:00:00" --until="$END 23:59:59" --date=short
          --format='%H%x09%h%x09%ad%x09%an%x09%s')
$NO_MERGES && log_args+=(--no-merges)
COMMITS="$(git log "${log_args[@]}")"
[[ -n "$COMMITS" ]] || die "no commits on $REF between $START and $END"

# The newest commit in the range is the release target. It is taken without
# --no-merges so a merge commit that closes the range is still what gets tagged.
TARGET_LINE="$(git log "$REF" --since="$START 00:00:00" --until="$END 23:59:59" --date=short \
               --format='%H%x09%h%x09%ad%x09%an%x09%s' -1)"
IFS=$'\t' read -r TARGET TARGET_SHORT TARGET_DATE _ TARGET_SUBJECT <<<"$TARGET_LINE"
COUNT="$(printf '%s\n' "$COMMITS" | wc -l | tr -d ' ')"

if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  die "tag '$TAG' already exists locally"
fi
if git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag '$TAG' already exists on $REMOTE"
fi

# --- Build release notes ------------------------------------------------------

NOTES="$(mktemp "${TMPDIR:-/tmp}/release-notes.XXXXXX")"
trap 'rm -f "$NOTES"' EXIT

{
  echo "## Changes from $START to $END"
  echo
  while IFS=$'\t' read -r _ short date author subject; do
    echo "- $subject ($short) — $author, $date"
  done <<<"$COMMITS"
  # Link to the full diff when the range doesn't start at the first commit.
  first="$(printf '%s\n' "$COMMITS" | tail -1 | cut -f1)"
  if base="$(git rev-parse --verify --quiet "$first^" 2>/dev/null)"; then
    echo
    echo "**Full diff:** https://github.com/$REPO/compare/${base:0:12}...$TAG"
  fi
} >"$NOTES"

echo
echo "Repository:  $REPO"
echo "Branch:      $REF"
echo "Date range:  $START to $END ($COUNT commit$([[ $COUNT == 1 ]] || echo s))"
echo "Tag:         $TAG -> $TARGET_SHORT ($TARGET_DATE) $TARGET_SUBJECT"
echo "Title:       $TITLE$($DRAFT && echo ' [draft]')$($PRERELEASE && echo ' [pre-release]')"
echo
echo "----- release notes -----"
cat "$NOTES"
echo "-------------------------"
echo

gh_args=(release create "$TAG" --repo "$REPO" --target "$TARGET" --title "$TITLE" --notes-file "$NOTES")
$DRAFT && gh_args+=(--draft)
$PRERELEASE && gh_args+=(--prerelease)

if $DRY_RUN; then
  echo "Dry run: nothing created. Would run:"
  printf '  gh'; printf ' %q' "${gh_args[@]}"; echo
  exit 0
fi

# --- Create the release -------------------------------------------------------

if ! $ASSUME_YES; then
  [[ -t 0 ]] || die "not running interactively; pass --yes to create the release"
  read -r -p "Create release $TAG on $REPO? [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Cancelled."; exit 1; }
fi

# gh creates the tag on GitHub at --target, since the tag doesn't exist yet.
gh "${gh_args[@]}"
git fetch --quiet --tags "$REMOTE" || true
echo "Done: $TAG now points at $TARGET_SHORT."
