# Skills

As skills seguem o padrão `SKILL.md`. Cada agente vê só o nome e a descrição de cada skill instalada; as instruções completas são carregadas quando a tarefa pede ou quando a skill é chamada pelo nome (por exemplo, `/brainstorming`). Por isso o conjunto pode variar conforme a necessidade, sem uma lista fixa.

| Camada | Conteúdo | Onde fica no container |
|---|---|---|
| Base | Superpowers fixado em `versions.env`, filtrado por `profiles/base.txt` | `/opt/skills/base`, só leitura |
| Projeto | Skills e `AGENTS.md` do próprio projeto (`.agents/skills` ou `.claude/skills`) | No repositório do projeto |
| Perfis extras | Outros `profiles/<perfil>.txt` (ex.: `frontend`), montados com `--skills-dir $SKILLS_PREFIX/profiles/<perfil>` | `/opt/skills/extra-N`, só leitura |
| Pessoal | Skills próprias do autor, opcionais | Montadas só para leitura |

**Fontes dos perfis** (`scripts/fetch-skills.sh <perfil>...`): uma linha sem prefixo é skill do Superpowers; `anthropic:<nome>` é skill de `anthropics/skills`, fixada por commit em `versions.env` (o repositório não tem tags). Dele só se baixam as pastas usadas, e cada uma traz o próprio `LICENSE.txt`.

**Cuidados com o modelo local**
- **Custo fixo por skill:** cada skill instalada acrescenta ~50–150 tokens a todo prompt. Use perfis enxutos por projeto em vez de instalar tudo.
- **Acionamento:** quem decide quando usar uma skill é o modelo, e um modelo pequeno aciona com menos precisão. Compense com chamada explícita (`/nome`) ou com um `AGENTS.md` que diga qual skill usar em cada fase.
- **Ferramentas exclusivas do Claude Code:** algumas skills dependem de `Task` ou `TodoWrite`. O Superpowers traz mapeamento oficial para Codex e Pi (`references/codex-tools.md`, `pi-tools.md`); Qwen Code e OpenCode não têm e podem funcionar pior.

Na E6 mede-se, por agente, se o carregamento sob demanda funciona, se o modelo aciona a skill certa sozinho e se a chamada explícita funciona.
