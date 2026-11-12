"""K2 hidden tests: Field[a:b] must equal Field.between(a, b)."""
import unittest
from datetime import date

from pypika import Field, Query, Table


class HiddenSliceBetweenTests(unittest.TestCase):
    def test_slice_equals_between(self):
        for lo, hi in ((0, 1), (5, 10), (date(2000, 1, 1), date(2000, 12, 31)), ("a", "c")):
            self.assertEqual(str(Field("foo").between(lo, hi)), str(Field("foo")[lo:hi]))

    def test_slice_order(self):
        self.assertEqual('"foo" BETWEEN 1 AND 9', str(Field("foo")[1:9]))

    def test_slice_in_query(self):
        t = Table("abc")
        q = Query.from_(t).select(t.foo).where(t.bar[10:20])
        self.assertEqual('SELECT "foo" FROM "abc" WHERE "bar" BETWEEN 10 AND 20', str(q))


if __name__ == "__main__":
    unittest.main()
