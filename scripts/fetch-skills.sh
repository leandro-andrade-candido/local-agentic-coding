#!/usr/bin/env bash
# Downloads the skills pinned in versions.env and materializes the profiles. Two sources:
#   Superpowers (default): a single shallow commit, whole tree (git archive, no .git)
#     -> $SKILLS_PREFIX/superpowers/$SUPERPOWERS_VERSION/, with LICENSE
#   anthropic:<name> (anthropics/skills): large repo without tags, so it downloads only the
#     folders used, at the pinned commit -> $SKILLS_PREFIX/anthropic-skills/<commit>/<name>/
#     (each skill carries its own LICENSE.txt)
#   $SKILLS_PREFIX/profiles/<profile>/  only the skills listed in skills/profiles/<profile>.txt
#                                       (copies), licenses and SOURCE
# Downloaded commits are checked against the pinned ones (and the Superpowers tag against the
# version, when the server answers). Everything is read-only. The agents get the base
# profile through AGENT_SKILLS_DIRS (default: $SKILLS_PREFIX/profiles/base on the host,
# /opt/skills/base in the agent-box); the others come in with --skills-dir. See agents/README.md.
# Usage: scripts/fetch-skills.sh [profile...]   (default: base)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
prefix_override="${SKILLS_PREFIX:-}"
source "$ROOT/versions.env"
# SKILLS_PREFIX in the environment overrides versions.env (useful for testing in another folder).
[ -z "$prefix_override" ] || SKILLS_PREFIX="$prefix_override"
: "${SUPERPOWERS_REPO:?}" "${SUPERPOWERS_VERSION:?}" "${SUPERPOWERS_COMMIT:?}" "${SKILLS_PREFIX:?}"
: "${ANTHROPIC_SKILLS_REPO:?}" "${ANTHROPIC_SKILLS_COMMIT:?}"
export GIT_TERMINAL_PROMPT=0

die() { echo "error: $*" >&2; exit 1; }
profiles=("$@")
[ ${#profiles[@]} -gt 0 ] || profiles=(base)

# Valid lines of a profile: without comments or whitespace.
profile_lines() {
  local list="$ROOT/skills/profiles/$1.txt" line name
  [ -f "$list" ] || die "profile does not exist: $list"
  while IFS= read -r line; do
    name="${line%%#*}"; name="$(echo "$name" | tr -d '[:space:]')"
    [ -z "$name" ] || echo "$name"
  done < "$list"
}

src="$SKILLS_PREFIX/superpowers/$SUPERPOWERS_VERSION"
asrc="$SKILLS_PREFIX/anthropic-skills/$ANTHROPIC_SKILLS_COMMIT"
mkdir -p "$SKILLS_PREFIX/superpowers" "$SKILLS_PREFIX/anthropic-skills" "$SKILLS_PREFIX/profiles"
work="$(mktemp -d "$SKILLS_PREFIX/.fetch-XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

needs_superpowers=0
anthropic_missing=()
for profile in "${profiles[@]}"; do
  lines="$(profile_lines "$profile")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      anthropic:*) n="${name#anthropic:}"
                   [ -f "$asrc/$n/SKILL.md" ] || anthropic_missing+=("$n") ;;
      *) needs_superpowers=1 ;;
    esac
  done <<<"$lines"
done

if [ "$needs_superpowers" = 1 ] && { [ ! -f "$src/.commit" ] || [ "$(cat "$src/.commit")" != "$SUPERPOWERS_COMMIT" ]; }; then
  git -C "$work" init -q repo
  git -C "$work/repo" remote add origin "https://github.com/$SUPERPOWERS_REPO"
  git -C "$work/repo" fetch -q --depth 1 origin "$SUPERPOWERS_COMMIT"
  got="$(git -C "$work/repo" rev-parse FETCH_HEAD)"
  [ "$got" = "$SUPERPOWERS_COMMIT" ] || die "downloaded commit ($got) differs from the pinned one ($SUPERPOWERS_COMMIT)"
  tag="$(git ls-remote "https://github.com/$SUPERPOWERS_REPO" "refs/tags/$SUPERPOWERS_VERSION^{}" | cut -f1 || true)"
  if [ -n "$tag" ] && [ "$tag" != "$SUPERPOWERS_COMMIT" ]; then
    die "tag $SUPERPOWERS_VERSION points to $tag, not to the pinned commit"
  fi
  mkdir "$work/tree"
  git -C "$work/repo" archive FETCH_HEAD | tar -x -C "$work/tree"
  [ -f "$work/tree/LICENSE" ] || die "LICENSE missing upstream"
  echo "$SUPERPOWERS_COMMIT" > "$work/tree/.commit"
  if [ -e "$src" ]; then chmod -R u+w "$src"; rm -rf "$src"; fi
  mv "$work/tree" "$src"
  chmod -R a-w "$src"
  echo "superpowers $SUPERPOWERS_VERSION ($SUPERPOWERS_COMMIT) in $src"
fi

if [ ${#anthropic_missing[@]} -gt 0 ]; then
  # Partial clone (no blobs); git archive fetches only the files of the requested folders.
  git -C "$work" init -q arepo
  git -C "$work/arepo" remote add origin "https://github.com/$ANTHROPIC_SKILLS_REPO"
  git -C "$work/arepo" fetch -q --depth 1 --filter=blob:none origin "$ANTHROPIC_SKILLS_COMMIT"
  got="$(git -C "$work/arepo" rev-parse FETCH_HEAD)"
  [ "$got" = "$ANTHROPIC_SKILLS_COMMIT" ] || die "downloaded commit ($got) differs from the pinned one ($ANTHROPIC_SKILLS_COMMIT)"
  mkdir -p "$asrc"; chmod u+w "$asrc"
  for n in "${anthropic_missing[@]}"; do
    [ -e "$asrc/$n" ] && continue   # repeated in two profiles
    git -C "$work/arepo" cat-file -e "FETCH_HEAD:skills/$n/SKILL.md" 2>/dev/null \
      || die "skill 'anthropic:$n' does not exist in $ANTHROPIC_SKILLS_REPO@$ANTHROPIC_SKILLS_COMMIT"
    mkdir -p "$work/atree"
    git -C "$work/arepo" archive FETCH_HEAD "skills/$n" | tar -x -C "$work/atree"
    ls "$work/atree/skills/$n"/LICENSE* >/dev/null 2>&1 || die "skill 'anthropic:$n' has no LICENSE in its folder"
    mv "$work/atree/skills/$n" "$asrc/$n"
    chmod -R a-w "$asrc/$n"
    echo "anthropic:$n ($ANTHROPIC_SKILLS_COMMIT) in $asrc/$n"
  done
  chmod a-w "$asrc"
fi

for profile in "${profiles[@]}"; do
  lines="$(profile_lines "$profile")"
  out="$work/profile-$profile"
  mkdir -p "$out"
  names=(); has_sp=0; has_an=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      anthropic:*)
        n="${name#anthropic:}"
        cp -R "$asrc/$n" "$out/$n"   # brings the skill's own LICENSE.txt
        has_an=1 ;;
      *)
        n="$name"
        [ -f "$src/skills/$n/SKILL.md" ] || die "skill '$n' (profile $profile) does not exist in Superpowers $SUPERPOWERS_VERSION"
        # Copy of the whole folder (prompts, scripts, references). Cross-references
        # between skills of the base profile stay inside the profile itself.
        cp -R "$src/skills/$n" "$out/$n"
        has_sp=1 ;;
    esac
    names+=("$name")
  done <<<"$lines"
  [ "$has_sp" = 0 ] || cp "$src/LICENSE" "$out/LICENSE.superpowers"
  {
    if [ "$has_sp" = 1 ]; then
      echo "repo=$SUPERPOWERS_REPO"
      echo "version=$SUPERPOWERS_VERSION"
      echo "commit=$SUPERPOWERS_COMMIT"
    fi
    if [ "$has_an" = 1 ]; then
      echo "anthropic_repo=$ANTHROPIC_SKILLS_REPO"
      echo "anthropic_commit=$ANTHROPIC_SKILLS_COMMIT"
    fi
    echo "profile=$profile"
    echo "skills=${names[*]}"
  } > "$out/SOURCE"
  dest="$SKILLS_PREFIX/profiles/$profile"
  if [ -e "$dest" ]; then chmod -R u+w "$dest"; rm -rf "$dest"; fi
  mv "$out" "$dest"
  chmod -R a-w "$dest"
  echo "profile $profile: ${#names[@]} skills in $dest"
done
