I implemented a pagination helper in pypika, `QueryBuilder.paginate(page, per_page)`, and took the chance to simplify `_apply_pagination`. The changes are in the working tree, not committed yet (see them with `git diff`). The tests pass on my machine.

Before I commit, review the diff carefully, like a demanding reviewer: look for bugs and behavior changes I may have missed, including in code that already existed. If you find problems, fix them while keeping the new feature, and at the end tell me what you found and what you changed. No need to commit.

The dependencies are in `.venv` (tests: `.venv/bin/python -m pytest`).
