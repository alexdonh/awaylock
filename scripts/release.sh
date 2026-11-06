#!/usr/bin/env bash
# Stage a release: bump the version, write the CHANGELOG entry, commit, tag.
#
#   scripts/release.sh 1.0.0
#
# Does not push. Pushing the tag is what triggers .github/workflows/release.yml.
#
# Release notes: a hand-written "## Unreleased" section in CHANGELOG.md wins. Without one, the
# entry is generated from feat/fix/perf commit subjects since the previous tag.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "usage: scripts/release.sh <semver>   e.g. scripts/release.sh 1.0.0" >&2
  exit 1
fi
TAG="v$VERSION"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: tracked files are dirty; commit or stash first." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag $TAG already exists." >&2
  exit 1
fi

# BSD and GNU sed disagree on -i; write to a temp file instead.
sed_i() { local tmp; tmp="$(mktemp)"; sed "$1" "$2" > "$tmp" && mv "$tmp" "$2"; }

# Sparkle compares CFBundleVersion, so the build number goes up on every release.
CFG=Config/Base.xcconfig
BUILD=$(( $(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$CFG") + 1 ))
sed_i "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION/" "$CFG"
sed_i "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $BUILD/" "$CFG"
echo "==> $VERSION (build $BUILD)"

CHANGELOG=CHANGELOG.md
HEADER="## $VERSION ($(date +%Y-%m-%d))"
if grep -q '^## Unreleased$' "$CHANGELOG"; then
  sed_i "s/^## Unreleased$/$HEADER/" "$CHANGELOG"
else
  PREV="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  # "feat(scope): add x" -> "- Add x"
  section() {
    git log --no-merges --pretty=%s ${PREV:+"$PREV..HEAD"} \
      | sed -nE "s/^$1(\([^)]*\))?!?: (.*)/\2/p" \
      | awk '{ print "- " toupper(substr($0, 1, 1)) substr($0, 2) }'
  }
  ENTRY="$(mktemp)"
  echo "$HEADER" > "$ENTRY"
  for kind in "feat:New" "fix:Fixed" "perf:Faster"; do
    lines="$(section "${kind%%:*}")"
    [[ -n "$lines" ]] && printf '\n### %s\n\n%s\n' "${kind#*:}" "$lines" >> "$ENTRY"
  done
  [[ "$(wc -l < "$ENTRY")" -gt 1 ]] || printf '\n- Maintenance release.\n' >> "$ENTRY"
  echo >> "$ENTRY"
  # Splice above the previous release, keeping the file's header on top.
  FIRST="$(grep -n '^## ' "$CHANGELOG" | head -1 | cut -d: -f1)"
  if [[ -n "$FIRST" ]]; then
    { head -n "$((FIRST - 1))" "$CHANGELOG"; cat "$ENTRY"; tail -n "+$FIRST" "$CHANGELOG"; } > "$CHANGELOG.new"
  else
    { cat "$CHANGELOG"; echo; cat "$ENTRY"; } > "$CHANGELOG.new"
  fi
  mv "$CHANGELOG.new" "$CHANGELOG"
  rm -f "$ENTRY"
fi

git add "$CFG" "$CHANGELOG"
git commit -q -m "release: $TAG"
git tag -a "$TAG" -m "$TAG"

cat <<EOF

Release $TAG is staged locally. Nothing has been pushed.

Review:   git show HEAD
Edit notes, then:  git commit --amend -a --no-edit && git tag -f -a $TAG -m $TAG
Publish:  git push origin $(git rev-parse --abbrev-ref HEAD) $TAG
Undo:     git tag -d $TAG && git reset --hard HEAD~1
EOF
