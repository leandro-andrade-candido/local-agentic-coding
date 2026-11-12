# Skills

Skills follow the `SKILL.md` standard. Each agent sees only the name and description of every installed skill; the full instructions are loaded when the task calls for it or when the skill is invoked by name (for example, `/brainstorming`). That is why the set can vary with need, without a fixed list.

| Layer | Content | Where it lives in the container |
|---|---|---|
| Base | Superpowers pinned in `versions.env`, filtered by `profiles/base.txt` | `/opt/skills/base`, read-only |
| Project | The project's own skills and `AGENTS.md` (`.agents/skills` or `.claude/skills`) | In the project repository |
| Extra profiles | Other `profiles/<profile>.txt` (e.g. `frontend`), mounted with `--skills-dir $SKILLS_PREFIX/profiles/<profile>` | `/opt/skills/extra-N`, read-only |
| Personal | The author's own skills, optional | Mounted read-only |

**Profile sources** (`scripts/fetch-skills.sh <profile>...`): a line without a prefix is a Superpowers skill; `anthropic:<name>` is a skill from `anthropics/skills`, pinned by commit in `versions.env` (the repository has no tags). Only the folders in use are downloaded from it, and each one ships its own `LICENSE.txt`.

**Caveats for the local model**
- **Fixed cost per skill:** each installed skill adds ~50–150 tokens to every prompt. Use lean per-project profiles instead of installing everything.
- **Triggering:** the model decides when to use a skill, and a small model triggers less accurately. Compensate with an explicit call (`/name`) or with an `AGENTS.md` that says which skill to use in each phase.
- **Claude Code-only tools:** some skills depend on `Task` or `TodoWrite`. Superpowers ships an official mapping for Codex and Pi (`references/codex-tools.md`, `pi-tools.md`); Qwen Code and OpenCode have none and may work worse.

In E6 we measure, per agent, whether on-demand loading works, whether the model triggers the right skill on its own and whether the explicit call works.
