#!/usr/bin/env bash
# Baixa o Superpowers fixado em versions.env (um commit só, raso) e materializa:
#   $SKILLS_PREFIX/superpowers/$SUPERPOWERS_VERSION/  árvore do upstream nesse commit
#                                                     (git archive, sem .git), com LICENSE
#   $SKILLS_PREFIX/profiles/<perfil>/                 só as skills listadas em
#                                                     skills/profiles/<perfil>.txt (cópias),
#                                                     LICENSE.superpowers e SOURCE
# O commit baixado é conferido contra SUPERPOWERS_COMMIT (e a tag contra a versão,
# quando o servidor responde). Tudo fica só leitura. Os agentes recebem o perfil por
# AGENT_SKILLS_DIRS (padrão: $SKILLS_PREFIX/profiles/base no host, /opt/skills/base
# no agent-box); ver agents/README.md.
# Uso: scripts/fetch-skills.sh [perfil...]   (padrão: base)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
prefix_override="${SKILLS_PREFIX:-}"
source "$ROOT/versions.env"
# SKILLS_PREFIX no ambiente vence o versions.env (útil para testar em outra pasta).
[ -z "$prefix_override" ] || SKILLS_PREFIX="$prefix_override"
: "${SUPERPOWERS_REPO:?}" "${SUPERPOWERS_VERSION:?}" "${SUPERPOWERS_COMMIT:?}" "${SKILLS_PREFIX:?}"
export GIT_TERMINAL_PROMPT=0

die() { echo "erro: $*" >&2; exit 1; }
profiles=("$@")
[ ${#profiles[@]} -gt 0 ] || profiles=(base)

src="$SKILLS_PREFIX/superpowers/$SUPERPOWERS_VERSION"
mkdir -p "$SKILLS_PREFIX/superpowers" "$SKILLS_PREFIX/profiles"
work="$(mktemp -d "$SKILLS_PREFIX/.fetch-XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

if [ ! -f "$src/.commit" ] || [ "$(cat "$src/.commit")" != "$SUPERPOWERS_COMMIT" ]; then
  git -C "$work" init -q repo
  git -C "$work/repo" remote add origin "https://github.com/$SUPERPOWERS_REPO"
  git -C "$work/repo" fetch -q --depth 1 origin "$SUPERPOWERS_COMMIT"
  got="$(git -C "$work/repo" rev-parse FETCH_HEAD)"
  [ "$got" = "$SUPERPOWERS_COMMIT" ] || die "commit baixado ($got) difere do fixado ($SUPERPOWERS_COMMIT)"
  tag="$(git ls-remote "https://github.com/$SUPERPOWERS_REPO" "refs/tags/$SUPERPOWERS_VERSION^{}" | cut -f1 || true)"
  if [ -n "$tag" ] && [ "$tag" != "$SUPERPOWERS_COMMIT" ]; then
    die "a tag $SUPERPOWERS_VERSION aponta para $tag, não para o commit fixado"
  fi
  mkdir "$work/tree"
  git -C "$work/repo" archive FETCH_HEAD | tar -x -C "$work/tree"
  [ -f "$work/tree/LICENSE" ] || die "LICENSE ausente no upstream"
  echo "$SUPERPOWERS_COMMIT" > "$work/tree/.commit"
  if [ -e "$src" ]; then chmod -R u+w "$src"; rm -rf "$src"; fi
  mv "$work/tree" "$src"
  chmod -R a-w "$src"
  echo "superpowers $SUPERPOWERS_VERSION ($SUPERPOWERS_COMMIT) em $src"
fi

for profile in "${profiles[@]}"; do
  list="$ROOT/skills/profiles/$profile.txt"
  [ -f "$list" ] || die "perfil inexistente: $list"
  out="$work/profile-$profile"
  mkdir -p "$out"
  names=()
  while IFS= read -r line; do
    name="${line%%#*}"; name="$(echo "$name" | tr -d '[:space:]')"
    [ -n "$name" ] || continue
    [ -f "$src/skills/$name/SKILL.md" ] || die "skill '$name' (perfil $profile) não existe no Superpowers $SUPERPOWERS_VERSION"
    # Cópia da pasta inteira (prompts, scripts, references). As referências cruzadas
    # entre skills do perfil base ficam dentro do próprio perfil.
    cp -R "$src/skills/$name" "$out/$name"
    names+=("$name")
  done < "$list"
  cp "$src/LICENSE" "$out/LICENSE.superpowers"
  {
    echo "repo=$SUPERPOWERS_REPO"
    echo "version=$SUPERPOWERS_VERSION"
    echo "commit=$SUPERPOWERS_COMMIT"
    echo "profile=$profile"
    echo "skills=${names[*]}"
  } > "$out/SOURCE"
  dest="$SKILLS_PREFIX/profiles/$profile"
  if [ -e "$dest" ]; then chmod -R u+w "$dest"; rm -rf "$dest"; fi
  mv "$out" "$dest"
  chmod -R a-w "$dest"
  echo "perfil $profile: ${#names[@]} skills em $dest"
done
