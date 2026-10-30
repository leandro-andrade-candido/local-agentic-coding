#!/usr/bin/env bash
# Sessão interativa de um agente dentro do agent-box, com só o projeto montado.
#
# Uso: sandbox/agent-shell.sh [--skills-dir <dir>]... <agente|shell> <projeto> [opções do agente...]
#   agente: qwen-code | pi | opencode | claude-local | codex-local
#   shell:  bash no container, com o mesmo isolamento (para rodar testes, git, etc.)
#   --skills-dir: skills pessoais, só leitura em /opt/skills/extra-N (repetível)
#   --net: libera rede externa (internet/DNS). Padrão: sem rede, só o modelo local.
#
# - Monta <projeto> com leitura e escrita no mesmo caminho absoluto; nada mais da
#   HOME do host. agents/ entra só leitura (lançadores e configuração).
# - Perfil do agente: AGENT_PROFILE=interactive (padrão dos lançadores) ou autonomous.
# - Estado do agente (sessões, config gerada) em
#   ~/.local/state/local-agentic/agent-box/<agente>, separado do estado dos
#   lançadores usados direto no host: o que o agente grava no container nunca é
#   lido por um agente rodando fora dele.
# - Skills: perfil base em /opt/skills/base, pessoais em /opt/skills/extra-N, as do
#   projeto (.agents/skills, .claude/skills) vêm com ele; lista em AGENT_SKILLS_DIRS.
# - .git do projeto protegido (--protect-git): config e hooks só leitura e auditoria
#   no fim da sessão. O resto do projeto, inclusive o histórico em .git, pode ser
#   alterado ou apagado pelo agente: trabalhe numa cópia ou worktree.
# - Codex: o sandbox próprio (bubblewrap) não funciona no container; a sessão usa
#   --sandbox danger-full-access, com a aprovação do perfil (on-request).
#   BOX_CODEX_SANDBOX muda o valor.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

usage() { box_usage "$0" >&2; exit 2; }
box_args=()
while [ "${1:-}" = --skills-dir ] || [ "${1:-}" = --net ]; do
    if [ "$1" = --net ]; then box_args+=(--net); shift; continue; fi
    box_args+=(--skills-dir "${2:?--skills-dir sem caminho}")
    shift 2
done
[ $# -ge 2 ] || usage
harness="$1" proj="$2"
shift 2
[ -d "$proj" ] || box_die "projeto não existe: $proj"
proj="$(cd "$proj" && pwd)"

case "$harness" in
    qwen-code) launcher=qwen-local ;;
    pi) launcher=pi-local ;;
    opencode) launcher=opencode-local ;;
    claude-local) launcher=claude-local ;;
    codex-local) launcher=codex-local ;;
    shell) launcher="" ;;
    *) usage ;;
esac

# Identidade do git dos commits feitos no container: a global do host (só nome e
# e-mail; nada da configuração do host entra no container).
if [ -z "${GIT_AUTHOR_NAME:-}" ]; then
    n="$(git config --global --get user.name 2>/dev/null || true)"
    e="$(git config --global --get user.email 2>/dev/null || true)"
    if [ -n "$n" ] && [ -n "$e" ]; then
        export GIT_AUTHOR_NAME="$n" GIT_COMMITTER_NAME="$n" GIT_AUTHOR_EMAIL="$e" GIT_COMMITTER_EMAIL="$e"
    fi
fi

args=(--tty --rw "$proj" --cwd "$proj" --protect-git "$proj" "${box_args[@]}")
if [ -z "$launcher" ]; then
    cmd=(bash -l)
else
    state="${AGENT_BOX_STATE:-$HOME/.local/state/local-agentic/agent-box}"
    mkdir -p "$state/$harness"
    chmod 700 "$state"
    args+=(--rw "$state/$harness" --env "AGENTS_STATE=$state")
    cmd=("$AGENTS_DIR/$harness/$launcher")
    if [ "$harness" = codex-local ]; then
        cmd+=(--sandbox "${BOX_CODEX_SANDBOX:-danger-full-access}")
    fi
fi

exec "$SANDBOX_DIR/run-in-box.sh" "${args[@]}" -- "${cmd[@]}" "$@"
