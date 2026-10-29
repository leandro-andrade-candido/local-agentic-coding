## Qwen Code tool mapping

Skills speak in actions ("invoke a skill", "dispatch a subagent", "create a todo"). In Qwen Code they resolve to these tools:

| Action skills request | Qwen Code equivalent |
|---|---|
| Invoke a skill | the `skill` tool (or the user types `/<skill-name>`) |
| Read a file | `read_file` |
| Create a new file | `write_file` |
| Edit a file | `edit` |
| Run a shell command | `run_shell_command` |
| Search file contents | `grep_search` |
| Find files by name | `glob` |
| Dispatch a subagent (`Subagent (general-purpose):`) | the `agent` tool, if it is in your tool list; otherwise do the work yourself in this session |
| Task tracking ("create a todo", "mark complete") | `todo_write` if it is in your tool list; otherwise keep the checklist in the plan file or a repo-local `TODO.md` |

Treat older `TodoWrite`, `Task` or `Skill` references as the actions above. Never invent a tool that is not in your tool list. When a skill mentions "your instructions file", that is `AGENTS.md` (or `QWEN.md`) in the project.
