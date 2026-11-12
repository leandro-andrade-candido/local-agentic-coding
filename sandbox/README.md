# agent-box container (E7)

The real barrier for agents in autonomous mode (yolo, `bypassPermissions`,
`danger-full-access`, no approvals). Each agent's rules and the shared guard
(`agents/lib/guard.py`) are the second layer. This folder is the first.

**Status (2026-10-29): built and verified (phase 2).**

| Check | Result |
|---|---|
| `sandbox/build.sh` | `agent-box:latest` image of 2.89 GB (agents layer: 1.63 GB); the 5 tarballs match `versions.env`, and each one's `--version` exits 0 |
| `sandbox/escape-tests.sh` | 150 of 150: 127 inside the container, 2 with the real llama-server (`/health` and `/v1/models` with the key) and 21 on the host (13 regression tests for item 7: the host does not follow agent symlinks; box_post and box_check do not let the agent forge the scoreboard) |
| Eval with `fake-oracle` through the wrapper | S1 (pytest, 1360 + 3 tests) passes; S2 (jest, 753 + 3 tests) passes; S3 with `sleep:60` and `EVAL_TIMEOUT_S=5` exits with 124, `timed_out: true`, with no container, forwarder or temporary folder left behind |
| Codex sandbox in the container | `codex sandbox -- true` fails: `bwrap: No permissions to create a new namespace` (expected; see below) |
| Autonomous-profile lock (`agents/lib/common.sh`) | released in the container (`AGENT_BOX=1` and `/.dockerenv`), refused on the host |

Also verified: the HOME tmpfs accepts `uid=`/`gid=`; `/.dockerenv` exists even with
`--read-only`; Docker 29's default seccomp blocks `AF_VSOCK`; the Windows binary
(WSL interop) does not run; the forwarder delivers SSE event by event
(0.0/0.3/0.6/0.9/1.2 s), 4 connections of 1.5 s in 1.51 s, and 4 MiB round trip.

What is still to be seen, with the real agents in E6, is under "Open items".

## Files

| File | Role |
|---|---|
| `Dockerfile` | `agent-box` image: Ubuntu 24.04 pinned by digest, Node 24.22.2, Python 3.12, uv 0.12.13, git, ripgrep, fd, jq, Playwright 1.64.1 with headless Chromium, and the 5 agents |
| `install-agents.sh` | Installs the agents at build time; checks each tarball's sha512 against `agents/versions.env` |
| `build.sh` | Builds the image with the UID/GID of whoever runs it and the versions label |
| `run-in-box.sh` | Runs a command in a new container, with the requested mounts and nothing else |
| `llm-forward.py` | TCP ↔ unix socket forwarder (standard library only): the container's only way out |
| `entrypoint.sh` | Starts the internal forwarder and runs the command |
| `agent-shell.sh` | Interactive session of an agent (or bash) with only one project mounted |
| `escape-tests.sh` | Escape tests (run inside the container, with checks on the host) |
| `lib.sh` | Shared functions |

## Usage

```bash
sandbox/build.sh                    # builds agent-box:latest (2.89 GB; ~2 min with a cold apt cache)
sandbox/escape-tests.sh             # escape tests; exit 0 = everything passed

# eval: agent, diff capture and checks in containers (see eval/README.md)
EVAL_WRAPPER=sandbox/run-in-box.sh eval/run.sh qwen-code S1 batch1

# interactive session in a project (only it is mounted)
sandbox/agent-shell.sh claude-local ~/projects/pilot-copy
sandbox/agent-shell.sh shell ~/projects/pilot-copy     # bash with the same isolation
sandbox/agent-shell.sh --skills-dir ~/my-skills pi ~/projects/x   # + personal skills
AGENT_PROFILE=autonomous sandbox/agent-shell.sh qwen-code ~/projects/x

# any command; for example, measuring an agent's preamble (E6) inside the container
sandbox/run-in-box.sh --rw ~/projects/x -- bash -lc 'cd ~/projects/x && npm test'
mkdir -p ~/.cache/local-agentic/preamble/pi
sandbox/run-in-box.sh --rw ~/.cache/local-agentic/preamble/pi -- \
    "$PWD/agents/measure-preamble.sh" pi ~/.cache/local-agentic/preamble/pi
```

`run-in-box.sh` refuses an image built with other agent versions
(label `local-agentic.agents-versions`). After changing `agents/versions.env`,
run `sandbox/build.sh` again.

## Design

### Container

| `docker run` option | Why |
|---|---|
| `--network none` | No interface besides `lo`: no internet, no WSL network, no `docker0` bridge, no Windows. The host's abstract unix sockets are also left out, because they belong to the network namespace. |
| Forwarder over a unix socket | The only way out. The destination is fixed (`127.0.0.1:<LLM_BASE_URL port>`). See "Network". |
| `--read-only` + tmpfs on `/tmp`, `/var/tmp` and `HOME` (`/home/agent`) | Nothing outside the mounts persists or changes the image. HOME is empty on every run. |
| Mounts at the same absolute path | The eval's `.venv` directories have absolute paths (shebangs, `pyvenv.cfg`), and the `run.sh` scripts use `pwd -P`. Logs end up identical to the host's. |
| `agents/` read-only | Launchers, configuration, guard. The agent cannot change its own guard. |
| `--user <UID>:<GID>` of the host, no `sudo` and no setuid | Does not run as root (Claude Code refuses `bypassPermissions` as root), and created files get the right owner. |
| `--cap-drop ALL`, `--security-opt no-new-privileges` | No capabilities, no privilege gain through setuid. Docker's default seccomp stays on. |
| `--memory`/`--memory-swap` 8g, `--cpus 8`, `--pids-limit 2048`, `--oom-score-adj 500` | A looping agent does not take the machine down. Under memory pressure, the kernel kills the agent before llama-server. |
| `--init`, `--rm`, name and label `local-agentic.agent-box` | Reaps orphan processes and deletes the container at the end. SIGTERM, SIGINT and the eval timeout make the wrapper run `docker rm -f`. |
| `--runtime runc`, no `--gpus` | The agents do not need a GPU, and WSL's `/dev/dxg` stays out. |
| Environment by allowlist | The wrapper sets `AGENT_BOX=1` (the `run.sh` scripts in the autonomous profile refuse to run without it), `AGENT_SKILLS_DIRS`, `LLM_BASE_URL`, `HOME` and `TZ`; host values for them are ignored. Only `LLM_*` (includes the `LLM_API_KEY` key), the `AGENT_*`/`*_LOCAL_*` settings, `GIT_AUTHOR_*`/`GIT_COMMITTER_*` and a few others pass from the host. No `SSH_AUTH_SOCK`, `GITHUB_TOKEN`, `DOCKER_HOST`, `WSL_INTEROP` or cloud keys. |
| Skills read-only under `/opt/skills` | The agent uses the skills but cannot change the ones other sessions will load. See "Skills". |

Mounts refused by `run-in-box.sh`:

- `/` and the whole HOME, or an ancestor of it;
- `/tmp`, `/etc`, `/usr`, `/run`, `/var/run` (where the Docker and session sockets live), `/proc`, `/sys`, `/dev`;
- the Windows drives (`/mnt/c`...) and `/mnt/wsl*`;
- `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, `~/.config/gh`, `~/.claude*`, `~/.codex`, `~/.git-credentials` and the like.

### Network: the forwarder

```
agent ──HTTP──► 127.0.0.1:9931 inside the container   (llm-forward.py box)
                     │ unix socket /run/agent-box/llm.sock  (folder mounted read-only)
                     ▼
                 llm-forward.py host  (run-in-box.sh process, lasts as long as the container)
                     │ TCP
                     ▼
                 llama-server 127.0.0.1:9931 on the host
```

- The forwarder does not interpret HTTP: it copies bytes, with one thread per direction. That is why streaming (SSE), keep-alive, large bodies and several simultaneous connections work.
- End of sending on one side becomes a `shutdown` on the other. So an agent that gives up on a request closes the connection to llama-server, and the server cancels the generation.
- Inside the container, `LLM_BASE_URL` stays `http://127.0.0.1:<port>`, so the agents' configurations do not change. The same goes for the `/metrics` that the `run.sh` scripts read.
- The socket is `0600`, in a `0700` folder under `$XDG_RUNTIME_DIR`, and goes away at the end. The container has the same UID, so it connects. Another host user does not.
- With llama-server stopped, the forwarder accepts the connection and closes it right after. The client sees "connection closed", not "connection refused".

Discarded alternatives:

| Option | Problem |
|---|---|
| Bridge network + `host-gateway` | llama-server listens only on 127.0.0.1. It would have to be opened on `docker0` and filtered with iptables (no `sudo`), and the container would still see the rest of the host and the internet. |
| `--network host` | The container would get the host's whole network: the other local service on 8080, the internet and Windows. |
| `--internal` network + proxy container | More pieces, and the proxy would still need a path to the host's 127.0.0.1. |
| `socat` | Not installed, and installing it requires `sudo`. |

What goes through the forwarder is **any** llama-server route, not only
`/v1/*`. That is why, in E5, `--slot-save-path` and `POST /props` must stay off
(the default is already off). The E5 key (`LLM_API_KEY`) enters the container
because the agents need to send it. If it is not in the environment, `run-in-box.sh`
reads it from `LLM_API_KEY_FILE` (default `~/.config/local-agentic/llm-api-key`) and passes it
by name (`-e LLM_API_KEY`), never on the command line. The file itself does not enter. The key is only valid for llama-server, which the
container already reaches. See "Open items" for the alternative of injecting the key on
the host side.

### Skills

| Layer | Source on the host | In the container |
|---|---|---|
| Base | `$SKILLS_PREFIX/profiles/base` (`SKILLS_PREFIX` from the root `versions.env`; the environment variable overrides it), materialized by `scripts/fetch-skills.sh` | `/opt/skills/base`, read-only |
| Extra and personal profiles | `--skills-dir <dir>` (repeatable) or `BOX_SKILLS_DIRS=dir1:dir2`; e.g. `$SKILLS_PREFIX/profiles/frontend` | `/opt/skills/extra-1`, `extra-2`..., read-only |
| Project | the repository's `.agents/skills`, `.claude/skills` | come with the workdir/project (read-write, like the rest of it) |

- `AGENT_SKILLS_DIRS` lists the folders mounted under `/opt/skills`, separated by `:` (empty if none). The agents' launchers and `run.sh` decide how each agent loads them (see `skills/README.md`).
- Without the base profile on the host, the wrapper warns and continues without it.
- `--no-skills` mounts none. The eval uses this in the diff-capture and check containers.
- Project skills are not protected: the agent can rewrite them, like any project file, and what it writes applies in the next session on that project.

### Git

- **No credentials.** No SSH keys, SSH agent, `gh`, `~/.git-credentials`, `~/.gitconfig` or `credential.helper` enter (the image's `/etc/gitconfig` clears the helpers). Without a network, `git push` fails anyway.
- **Identity.** In the eval, the runner's fixed one (`GIT_AUTHOR_*`). In `agent-shell.sh`, the host's global name and email.
- **`.git` in `agent-shell.sh` (`--protect-git`).** The user will run `git status` on the host after the session, and `git` executes configuration commands: `core.fsmonitor`, filters, hooks. So:
  - `.git` becomes a mount point, so it cannot be renamed or swapped;
  - `.git/config`, `.git/hooks` and the `config` files under `.git/modules` are read-only;
  - at the end, a `.git/commondir` or `.git/config.worktree` created during the session is renamed to `*.agent-box-quarantine-<date>`, because it would make git read its configuration from elsewhere;
  - new nested `.git` repositories trigger a warning, because `git status` enters submodules and runs their configuration.
- Side effects: inside the container, local `git config`, `git remote add` and new hooks fail. A project that is a worktree (`.git` file) does not have git working inside, because the real gitdir is outside.
- To review on the host without executing anything from the repository:

  ```bash
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null status --ignore-submodules=all
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null diff --ignore-submodules=all
  ```

- **In the eval** there is no `--protect-git`, so as not to change the measured behavior. Instead, the host does not run git in the workdir after the agent: the diff capture runs in a container, with the workdir read-only, without the result folder mounted and with the agent's config neutralized; the diff comes out through stdout. And all output processing on the host (`eval/lib/boxio.py`) does not follow symlinks planted by the agent — see `docs/verifications/E7.md`, item 7.

### Codex and the agents' own sandboxes

- **Codex's sandbox (bubblewrap + seccomp, or the built-in helper) does not work inside this container.** It needs to create unprivileged user namespaces.
  - Docker's default seccomp blocks `unshare`/`clone` with `CLONE_NEWUSER` for those without `CAP_SYS_ADMIN`.
  - `no-new-privileges` neutralizes a setuid `bwrap`.
- To make it work, `seccomp=unconfined` (or a custom profile) and maybe `CAP_SYS_ADMIN` would be needed. That opens the kernel surface the container closes, which is worse than Codex's extra layer.
- Verified: `unshare -Ur` fails in the escape tests, and `codex sandbox -- true` (0.165; there is no `linux` subcommand) ends with `bwrap: No permissions to create a new namespace`.
- **Decision (same as in `agents/codex-local/`):**
  - in the eval, the `autonomous` profile already uses `sandbox_mode = "danger-full-access"` and `approval_policy = "never"`, and `CODEX_LOCAL_SANDBOX` stays empty;
  - in `agent-shell.sh`, the `interactive` profile (which asks for `workspace-write`) gets `--sandbox danger-full-access`, and the `on-request` approvals remain;
  - the `forbidden` rules and the `guard.py` hook still apply in both cases.
- Claude Code's bubblewrap sandbox stays off (it is not in the settings), for the same reason. Qwen Code, Pi and OpenCode have no sandbox of their own in use here.

## Threat model

**Protects against**, while the agent runs:

- **Writing outside** the workdir, the log dir, `/tmp`/`/var/tmp` and the temporary HOME. This covers the repository, the host HOME, the image, `agents/` and the guard.
- **Reading** the host HOME, keys, tokens and other agents' configurations (`~/.claude`, `~/.codex`). In the eval, also the hidden tests, the solutions and the other runs in `eval/`.
- **Changing the skills**, base and personal (mounted read-only).
- **Using the network:** internet, DNS, the other local service on 8080, other host ports, the Docker bridge, Windows (vsock and WSL interop) and the host's abstract sockets.
- **Gaining privilege:** root, `sudo`, setuid, capabilities, user namespaces, the Docker socket and the GPU.
- **Running `git push`** or any remote access with the user's credentials.
- **Exhausting resources** with a fork bomb, memory or CPU.
- **Leaving processes behind:** the container is removed at the end and on timeout.
- **Planting code that the host runs later**, in the cases covered:
  - in the eval, nothing from the workdir runs on the host after the agent;
  - in `agent-shell.sh`, `.git/config` and hooks are read-only, plus the `.git` audit.

**Does not protect against**:

- **Damage inside what was mounted.** The agent can delete or rewrite the whole project, including the local history in `.git`. Work on a copy or worktree, as the plan already foresees for the pilot, or with the important work already pushed to the remote.
- **Code the agent wrote and that you run later, on the host.** Examples:
  - `package.json` scripts (`npm install` runs `postinstall`);
  - `Makefile` and tests;
  - `.envrc` (direnv);
  - `.venv/bin/activate`;
  - VS Code tasks;
  - hooks that live in the working tree (`.husky/`, `.pre-commit-config.yaml` with `local` hooks).

  Review the diff first, or run in the container (`agent-shell.sh shell`).
- **Sensitive data inside the mounted project.** `.env` or credentials in the `.git/config` remote (`https://token@...`) are visible to the agent. Without a network, it does not send them out, but it can copy them into logs or code.
- **Abuse of llama-server.** The agent can call any route, generate text at will and occupy the single slot.
- **Eval scoreboard integrity:** the checks run **without the result folder mounted**. `check.sh` writes to a tmpfs in the container and returns the result as a tar on stdout; the host writes `checks.json` from the grader's verdict, not from a file the agent's code could plant. The grader (`eval/lib`), the task (with `hidden/` and the solution) and the transcript are mounted read-only; the agent's code only runs in the test subprocesses, separate from the grader. Output processing on the host does not follow agent symlinks (`eval/lib/boxio.py`). Known residue: in the tests the agent writes itself (T4/S3), its code runs in the same process as pytest/jest and could forge that process's report; closing this requires isolating the runner further. Fixes for item 7 of `docs/verifications/E7.md`.
- **Kernel, runc or Docker flaws** (container escape). The container is rootful and without `userns-remap`, but the process runs with the same unprivileged UID as the user, without capabilities and with seccomp. Such a flaw would give access to the host user, not to root, barring a second privilege-escalation flaw.
- **The wrapper killed with SIGKILL** before cleanup (for example, the timeout's `-k 30`, if SIGTERM is not enough). The container may be left over. Check with `docker ps --filter label=local-agentic.agent-box` and remove with `docker rm -f`.

## Limits and settings

| Variable | Default | Effect |
|---|---|---|
| `BOX_IMAGE` | `agent-box:latest` | Image used and built |
| `BOX_MEMORY` | `8g` | Memory (no swap) |
| `BOX_CPUS` | `8` | CPUs (quota). llama-server uses the rest when the two compete. |
| `BOX_PIDS` | `2048` | Processes and threads |
| `BOX_TMP_SIZE` / `BOX_HOME_SIZE` | `4g` / `1g` | Size of `/tmp` and HOME. It is memory and counts toward the limit above. |
| `BOX_ALLOW_STALE` | `0` | `1` accepts an image built with other agent versions |
| `BOX_SKILLS_DIRS` | empty | Personal skills folders, separated by `:` (same as `--skills-dir`) |
| `SKILLS_PREFIX` | from the root `versions.env` | Where `profiles/base` is |
| `BOX_DRY_RUN` | `0` | `1` only prints the assembled `docker run`, without checking the image or starting anything |
| `BOX_CODEX_SANDBOX` | `danger-full-access` | Value of Codex's `--sandbox` in `agent-shell.sh` |
| `AGENT_BOX_STATE` | `~/.local/state/local-agentic/agent-box` | State of the interactive sessions in the container |

The state of the interactive sessions is kept separate from the state of the
launchers used directly on the host (`~/.local/state/local-agentic/agents`). What an agent writes in the
container (config, sessions, MCP) is never read by an agent running outside it.
Do not point one at the other.

## Image

- **Base:** `ubuntu:24.04@sha256:24737cef…3573c`, published on 2026-10-25. It is Ubuntu, not Debian slim, because the system Python 3.12 lives at `/usr/bin/python3.12`, the same path as on the host. That way, the `.venv` directories the eval creates on the host with `uv venv --python 3.12` work inside the container without recreating anything.
- **Node 24.22.2 (LTS):** official tarball checked against the sha256 in `SHASUMS256.txt`. The host is on 24.21.0, which predates the security release 24.22.1.
- **uv 0.12.13:** GitHub tarball checked against the published sha256.
- **Playwright 1.64.1 (Python):** venv in `/opt/playwright`, installed from `playwright-requirements.txt` with `--require-hashes`; only the headless Chromium shell in `/opt/ms-playwright`, with the system libs and fonts (`--with-deps`), about +1.1 GB on the image. The Chromium download is checked by Playwright itself, not by a hash of ours. `python` calls that venv; `python3` remains the system one. It serves the `webapp-testing` skill (`frontend` profile). To regenerate: `echo playwright==<version> | uv pip compile - --generate-hashes --python-version 3.12 --python-platform x86_64-unknown-linux-gnu --no-header -o sandbox/playwright-requirements.txt`.
- **Agents:** `npm pack` of each package, with the file's sha512 compared to `*_INTEGRITY` in `agents/versions.env` before `npm install`.
  - The dependencies, including the native binaries of the optional dependencies (Codex, OpenCode, Claude Code), come from the registry, and npm checks each one against the published integrity.
  - They are not pinned by a lockfile.
  - Layout: `/opt/agents/<agent>/<version>` with the `current` link, as in `agents/install.sh`. `AGENTS_PREFIX=/opt/agents`.
- **apt:** packages come from the Ubuntu archive at build time, without a pinned version. For full reproducibility, `snapshot.ubuntu.com` can be used (see "Open items").
- **`EXTRA_APT_PACKAGES`:** `sandbox/build.sh --build-arg EXTRA_APT_PACKAGES=build-essential` installs compilers, if a project needs them. The eval tasks do not: pypika is pure Python, and chrono uses jest and ts-jest.

## Open items

Verification commands (repeat after changing the image or the wrapper):

```bash
sandbox/build.sh
sandbox/escape-tests.sh
EVAL_WRAPPER=sandbox/run-in-box.sh EVAL_FORCE=1 eval/run.sh fake-oracle S1 e7-sandbox
EVAL_WRAPPER=sandbox/run-in-box.sh EVAL_FORCE=1 eval/run.sh fake-oracle S2 e7-sandbox
EVAL_WRAPPER=sandbox/run-in-box.sh FAKE_ORACLE_MODE=sleep:60 EVAL_TIMEOUT_S=5 \
    EVAL_FORCE=1 eval/run.sh fake-oracle S3 e7-sandbox-timeout
```

To check with the real agents, in E6:

- whether OpenCode tries to install plugin dependencies over the network at startup, and how much that delays it;
- whether Qwen Code (YOLO) tries to use its own Docker/Podman sandbox;
- whether Pi loads `extensions/guard.ts` with `agents/` read-only (the jiti cache has to go to `/tmp`);
- whether any agent tries to write outside the temporary HOME and the log dir (the root is read-only);
- Codex warns that it does not create the "PATH aliases" when `CODEX_HOME` is in `/tmp`; in the eval it is in the log dir, and the effect on `apply_patch` must be checked.

Open:

- **Inject the key on the host:** the host forwarder would swap each request's `Authorization` for the E5 key, and the agents in the container would use a fake key. It requires interpreting HTTP/1.1 (keep-alive, chunked body); today the copy is byte-level.
- **apt by snapshot** (`snapshot.ubuntu.com`) so the image is bit-for-bit reproducible.
- **npm lockfile** per agent, to also pin the transitive dependencies.
- **Smaller image:** OpenCode installs the regular and `baseline` variants (205 MB each; `baseline` is for CPUs without AVX2), and Qwen Code brings Bun (103 MB) as an optional dependency. They can be removed at build time, at the cost of differing from the host install.
- **Isolate the test runner further** (T4/S3): today the code the agent writes runs in the same process as pytest/jest and could forge that process's report. Running each test file in a sub-sandbox without a shared `/tmp`, or validating the report against expected test IDs, would close the residue.
