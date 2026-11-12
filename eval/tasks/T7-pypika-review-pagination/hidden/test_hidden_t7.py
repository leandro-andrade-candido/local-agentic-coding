"""T7 hidden tests: the regression (LIMIT 0 disappears) must be fixed and paginate() kept."""
import unittest

from pypika import MSSQLQuery, OracleQuery, Query
from pypika.utils import QueryException


class HiddenLimitZeroTests(unittest.TestCase):
    def test_select_with_limit_zero(self):
        # Original upstream test (removed from the visible suite).
        self.assertEqual('SELECT "foo" FROM "abc" LIMIT 0', str(Query.from_("abc").select("foo")[:0]))
        self.assertEqual('SELECT "foo" FROM "abc" LIMIT 0', str(Query.from_("abc").select("foo").limit(0)))

    def test_limit_zero_with_offset(self):
        q = Query.from_("abc").select("foo").limit(0).offset(5)
        self.assertEqual('SELECT "foo" FROM "abc" LIMIT 0 OFFSET 5', str(q))

    def test_limit_none_means_no_limit(self):
        q = Query.from_("abc").select("foo").limit(10).limit(None)
        self.assertEqual('SELECT "foo" FROM "abc"', str(q))

    def test_offset_zero_is_still_omitted(self):
        # Upstream behavior before the diff: OFFSET 0 is not emitted.
        self.assertEqual('SELECT "foo" FROM "abc" LIMIT 3', str(Query.from_("abc").select("foo").limit(3).offset(0)))

    def test_mssql_limit_zero_unchanged(self):
        q = MSSQLQuery.from_("abc").select("foo").limit(0)
        self.assertEqual('SELECT "foo" FROM "abc" OFFSET 0 ROWS FETCH NEXT 0 ROWS ONLY', str(q))


class HiddenPaginateFeatureTests(unittest.TestCase):
    def test_first_page(self):
        self.assertEqual('SELECT "foo" FROM "abc" LIMIT 25', str(Query.from_("abc").select("foo").paginate(1, 25)))

    def test_third_page(self):
        q = Query.from_("abc").select("foo").orderby("foo").paginate(3, 10)
        self.assertEqual('SELECT "foo" FROM "abc" ORDER BY "foo" LIMIT 10 OFFSET 20', str(q))

    def test_invalid_values(self):
        with self.assertRaises(QueryException):
            Query.from_("abc").select("foo").paginate(0, 10)
        with self.assertRaises(QueryException):
            Query.from_("abc").select("foo").paginate(1, 0)

    def test_dialects(self):
        q = MSSQLQuery.from_("abc").select("foo").orderby("foo").paginate(3, 10)
        self.assertEqual('SELECT "foo" FROM "abc" ORDER BY "foo" OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY', str(q))
        q = OracleQuery.from_("abc").select("foo").paginate(2, 5)
        self.assertEqual("SELECT foo FROM abc OFFSET 5 ROWS FETCH NEXT 5 ROWS ONLY", str(q))

    def test_paginate_is_immutable(self):
        base = Query.from_("abc").select("foo")
        base.paginate(2, 10)
        self.assertEqual('SELECT "foo" FROM "abc"', str(base))


if __name__ == "__main__":
    unittest.main()
