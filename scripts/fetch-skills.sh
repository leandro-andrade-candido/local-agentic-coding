#!/usr/bin/env bash
# Baixa as skills fixadas em versions.env e materializa os perfis. Duas fontes:
#   Superpowers (padrão): um commit só, raso, árvore inteira (git archive, sem .git)
#     -> $SKILLS_PREFIX/superpowers/$SUPERPOWERS_VERSION/, com LICENSE
#   anthropic:<nome> (anthropics/skills): repo grande e sem tags, então baixa só as
#     pastas usadas, no commit fixado -> $SKILLS_PREFIX/anthropic-skills/<commit>/<nome>/
#     (cada skill traz o próprio LICENSE.txt)
#   $SKILLS_PREFIX/profiles/<perfil>/  só as skills listadas em skills/profiles/<perfil>.txt
#                                      (cópias), licenças e SOURCE
# Os commits baixados são conferidos contra os fixados (e a tag do Superpowers contra a
# versão, quando o servidor responde). Tudo fica só leitura. Os agentes recebem o perfil
# base por AGENT_SKILLS_DIRS (padrão: $SKILLS_PREFIX/profiles/base no host,
# /opt/skills/base no agent-box); os demais entram com --skills-dir. Ver agents/README.md.
# Uso: scripts/fetch-skills.sh [perfil...]   (padrão: base)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
prefix_override="${SKILLS_PREFIX:-}"
source "$ROOT/versions.env"
# SKILLS_PREFIX no ambiente vence o versions.env (útil para testar em outra pasta).
[ -z "$prefix_override" ] || SKILLS_PREFIX="$prefix_override"
: "${SUPERPOWERS_REPO:?}" "${SUPERPOWERS_VERSION:?}" "${SUPERPOWERS_COMMIT:?}" "${SKILLS_PREFIX:?}"
: "${ANTHROPIC_SKILLS_REPO:?}" "${ANTHROPIC_SKILLS_COMMIT:?}"
export GIT_TERMINAL_PROMPT=0

die() { echo "erro: $*" >&2; exit 1; }
profiles=("$@")
[ ${#profiles[@]} -gt 0 ] || profiles=(base)

# Linhas válidas de um perfil: sem comentário nem espaço.
profile_lines() {
  local list="$ROOT/skills/profiles/$1.txt" line name
  [ -f "$list" ] || die "perfil inexistente: $list"
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

if [ ${#anthropic_missing[@]} -gt 0 ]; then
  # Clone parcial (sem blobs); o git archive busca só os arquivos das pastas pedidas.
  git -C "$work" init -q arepo
  git -C "$work/arepo" remote add origin "https://github.com/$ANTHROPIC_SKILLS_REPO"
  git -C "$work/arepo" fetch -q --depth 1 --filter=blob:none origin "$ANTHROPIC_SKILLS_COMMIT"
  got="$(git -C "$work/arepo" rev-parse FETCH_HEAD)"
  [ "$got" = "$ANTHROPIC_SKILLS_COMMIT" ] || die "commit baixado ($got) difere do fixado ($ANTHROPIC_SKILLS_COMMIT)"
  mkdir -p "$asrc"; chmod u+w "$asrc"
  for n in "${anthropic_missing[@]}"; do
    [ -e "$asrc/$n" ] && continue   # repetida em dois perfis
    git -C "$work/arepo" cat-file -e "FETCH_HEAD:skills/$n/SKILL.md" 2>/dev/null \
      || die "skill 'anthropic:$n' não existe em $ANTHROPIC_SKILLS_REPO@$ANTHROPIC_SKILLS_COMMIT"
    mkdir -p "$work/atree"
    git -C "$work/arepo" archive FETCH_HEAD "skills/$n" | tar -x -C "$work/atree"
    ls "$work/atree/skills/$n"/LICENSE* >/dev/null 2>&1 || die "skill 'anthropic:$n' sem LICENSE na pasta"
    mv "$work/atree/skills/$n" "$asrc/$n"
    chmod -R a-w "$asrc/$n"
    echo "anthropic:$n ($ANTHROPIC_SKILLS_COMMIT) em $asrc/$n"
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
        cp -R "$asrc/$n" "$out/$n"   # traz o LICENSE.txt da própria skill
        has_an=1 ;;
      *)
        n="$name"
        [ -f "$src/skills/$n/SKILL.md" ] || die "skill '$n' (perfil $profile) não existe no Superpowers $SUPERPOWERS_VERSION"
        # Cópia da pasta inteira (prompts, scripts, references). As referências cruzadas
        # entre skills do perfil base ficam dentro do próprio perfil.
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
  echo "perfil $profile: ${#names[@]} skills em $dest"
done
