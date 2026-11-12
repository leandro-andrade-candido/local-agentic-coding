I ran the pypika suite and several BETWEEN tests in `pypika/tests/test_criterions.py` are failing (for example `test__between_number` and `test__between_date`). Nobody touched those tests.

Find the cause and fix it in the library, without changing the tests. At the end, tell me in a few lines what the cause was.

The dependencies are in `.venv` (tests: `.venv/bin/python -m pytest`).
