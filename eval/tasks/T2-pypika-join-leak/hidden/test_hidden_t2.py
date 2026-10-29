"""Testes ocultos do T2: joins não podem vazar entre queries derivadas da mesma base."""
import unittest

from pypika import MySQLQuery, PostgreSQLQuery, Query, Tables


class HiddenJoinImmutabilityTests(unittest.TestCase):
    a, b, c = Tables("a", "b", "c")

    def test_queries_after_join(self):
        # Teste original do upstream (removido da suíte visível).
        query1 = Query.from_(self.a).select(self.a.foo)
        query2 = query1.join(self.b).on(self.a.foo == self.b.bar).select(self.b.buz)

        self.assertEqual('SELECT "foo" FROM "a"', str(query1))
        self.assertEqual('SELECT "a"."foo","b"."buz" FROM "a" JOIN "b" ON "a"."foo"="b"."bar"', str(query2))

    def test_two_branches_do_not_share_joins(self):
        base = Query.from_(self.a).select(self.a.id)
        with_b = base.join(self.b).on(self.a.id == self.b.a_id)
        with_c = base.left_join(self.c).on(self.a.id == self.c.a_id)

        self.assertEqual('SELECT "id" FROM "a"', str(base))
        self.assertEqual('SELECT "a"."id" FROM "a" JOIN "b" ON "a"."id"="b"."a_id"', str(with_b))
        self.assertEqual('SELECT "a"."id" FROM "a" LEFT JOIN "c" ON "a"."id"="c"."a_id"', str(with_c))

    def test_chained_join_does_not_change_intermediate_query(self):
        q1 = Query.from_(self.a).join(self.b).using("id").select("*")
        q2 = q1.join(self.c).using("id")

        self.assertEqual('SELECT * FROM "a" JOIN "b" USING ("id")', str(q1))
        self.assertEqual('SELECT * FROM "a" JOIN "b" USING ("id") JOIN "c" USING ("id")', str(q2))

    def test_dialect_builders_do_not_share_joins(self):
        base = MySQLQuery.from_(self.a).select(self.a.x)
        joined = base.join(self.b).on(self.a.x == self.b.x)
        self.assertEqual("SELECT `x` FROM `a`", str(base))
        self.assertEqual("SELECT `a`.`x` FROM `a` JOIN `b` ON `a`.`x`=`b`.`x`", str(joined))

        pbase = PostgreSQLQuery.from_(self.a).select(self.a.x)
        pjoined = pbase.join(self.c).on(self.a.x == self.c.x)
        self.assertEqual('SELECT "x" FROM "a"', str(pbase))
        self.assertEqual('SELECT "a"."x" FROM "a" JOIN "c" ON "a"."x"="c"."x"', str(pjoined))

    def test_update_with_join_does_not_change_base(self):
        base = Query.update(self.a).set(self.a.flag, 1)
        joined = base.join(self.b).on(self.a.id == self.b.id).where(self.b.ok == 1)
        self.assertEqual('UPDATE "a" SET "flag"=1', str(base))
        self.assertIn('JOIN "b"', str(joined))

    def test_mutable_builder_still_mutates_in_place(self):
        q = Query.from_(self.a, immutable=False).select(self.a.id)
        same = q.join(self.b).on(self.a.id == self.b.id)
        self.assertIs(q, same)
        self.assertEqual('SELECT "a"."id" FROM "a" JOIN "b" ON "a"."id"="b"."id"', str(q))


if __name__ == "__main__":
    unittest.main()
