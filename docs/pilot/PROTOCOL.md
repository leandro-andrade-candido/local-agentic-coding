# End-to-end pilot: protocol

The pilot tests whether the local environment can deliver real software in a real, private project. The agent starts from a short description of a need and goes through requirements, specification, tasks, implementation with tests, delivery and review.

The project details live in `PILOTO.local.md`, outside git. This protocol does not name the project.

## Entry modes

The pilot is variable: each run picks one of the two modes.

| Mode | Starting point | First phase |
|---|---|---|
| A. Existing project | A real repository, with a copy or worktree mounted in the container | F1 = Code understanding |
| B. New project | The author's narrative: pain points, audience, expected deliveries of value | F1 = Brainstorm (`brainstorming` skill): questions, 2 or 3 approaches, a design document approved by the author |

In both modes, the flow follows the skills of the base profile (`skills/profiles/base.txt`): `brainstorming` → `writing-plans` → `subagent-driven-development` or `executing-plans` → `requesting-code-review` → `finishing-a-development-branch`. Contracts and services of a new project are born in F3 (specification). For a project with a user interface, the `frontend` profile is mounted as well (`frontend-design` for the visuals and `webapp-testing` to validate in the browser).

## Inputs

| Input | Provided by | Note |
|---|---|---|
| Description of the feature, in 2 to 5 lines: the problem, for whom, and what changes | author | No technical solution; eliciting the requirements is part of the test |
| Project code | copy or git worktree, mounted in the container | Code only. Personal and contractual documents are never mounted |
| Known constraints (deadline, technology, what cannot change) | author, optional | They go into the requirements |

## Phases

Each phase produces a file on its own branch of the copy. Approval points are planned and do not count as intervention. An intervention is any correction, hint or resumption that the author or the orchestrator has to make outside those points.

| Phase | The agent produces | Approval point |
|---|---|---|
| F1. Understanding (mode A) or Brainstorm (mode B) | A: `ARCHITECTURE.md` with modules, data flow and how to run, test and publish. B: `DESIGN.md` with the problem, the approaches considered and the chosen one | B: the author answers the questions and picks the approach |
| F2. Requirements | `REQUIREMENTS.md`: stories with acceptance criteria, out of scope, open questions | The author answers the questions and approves |
| F3. Specification | `SPEC.md`: design, affected files, data and migrations, API changes, test plan, risks | The author approves |
| F4. Tasks | `TASKS.md`: small tasks, in order, each with a definition of done | — |
| F5. Implementation | Code and tests task by task, with one commit per task and tests running at every step | — |
| F6. Delivery | Build, full suite, lint, local run and end-to-end verification of the new flow (with a UI: in the browser, through the `webapp-testing` skill, with desktop and mobile screenshots and no console errors). `DELIVERY.md` says what changed, how to verify it and what was left out | The author tests and accepts or rejects |
| F7. Review | Review of its own diff in a fresh session (or with the reviewer model), followed by the fixes | — |

## Metrics

Recorded per phase in `metrics.json`, in the pilot's private directory. Only the aggregates go into the repository.

- Wall-clock time, input and output tokens, prefill and generation speed (the server's `/metrics`)
- Unplanned interventions, with the reason for each
- Tool calls, tool errors and loops (`agent-metrics.json`)
- State of build, tests and lint at the end of each phase
- Defects the author finds after acceptance

## Evaluation

The author and the orchestrator each give a score from 0 to 2 on every item. The orchestrator evaluates only from the files produced and the diff, which are already in the pilot's artifacts. It does not read the rest of the project unless the author authorizes it.

| Item | 0 | 1 | 2 |
|---|---|---|---|
| Understanding or design | wrong or superficial | correct, with gaps | precise; in mode B, well-compared approaches |
| Requirements | incomplete or wrong | useful, with gaps | clear, testable, with a good out-of-scope list |
| Specification | unworkable or generic | workable, with unseen risks | precise, with risks and a test plan |
| Tasks | no order or criterion | ordered, without a clear criterion | small, ordered, with a definition of done |
| Code | does not follow the project | works, with rework needed | follows the conventions, ready to merge with minor adjustments |
| Tests | missing or trivial | cover the happy path | cover errors and edge cases and run in local CI |
| Delivery | does not work end to end | works with the author's fixes | works, with correct instructions |

## Approval criteria

The pilot passes if all of these hold:
1. The author accepts the delivered feature.
2. Build, tests and lint finish green.
3. At most 3 unplanned interventions.
4. No destructive action.
5. A total score of at least 9 out of 14, with no 0.

The planning scores (understanding or design, requirements, specification, tasks) and the execution scores (code, tests, delivery) are also recorded separately. They show whether splitting is worthwhile: plan with a stronger model and execute locally.

## Isolation and confidentiality

- **Execution:** always in the `agent-box` container (E7). Only the copy of the code is mounted, with no network other than the local server.
- **Models:** the local model only. A cloud reference run (Codex with the Go plan, or Claude) only happens after the local result and with prior approval: the orchestrator reports what will be sent, when, and the estimated consumption. Before that, the confidentiality clauses of the project's contract must be checked.
- **Artifacts:** the pilot's files (requirements, specification, diff, logs) stay outside this repository.
