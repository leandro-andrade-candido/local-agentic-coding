"""Testes ocultos do T6: CREATE VIEW conforme a especificação do task.md."""
import unittest

from pypika import Field, MySQLQuery, PostgreSQLQuery, Query, Table
from pypika.utils import QueryException


def pedidos_pagos():
    return Query.from_("pedidos").select("id", "total").where(Field("status") == "pago")


SELECT_SQL = 'SELECT "id","total" FROM "pedidos" WHERE "status"=\'pago\''


class HiddenCreateViewBasicsTests(unittest.TestCase):
    def test_basic(self):
        q = Query.create_view("v_pagos").as_select(pedidos_pagos())
        self.assertEqual('CREATE VIEW "v_pagos" AS ' + SELECT_SQL, str(q))

    def test_get_sql_matches_str(self):
        q = Query.create_view("v_pagos").as_select(pedidos_pagos())
        self.assertEqual(str(q), q.get_sql())

    def test_or_replace_with_columns(self):
        q = Query.create_view("v_pagos").or_replace().columns("pid", "valor").as_select(pedidos_pagos())
        self.assertEqual('CREATE OR REPLACE VIEW "v_pagos" ("pid","valor") AS ' + SELECT_SQL, str(q))

    def test_schema_and_if_not_exists(self):
        q = Query.create_view(Table("v_pagos", schema="relatorios")).if_not_exists().as_select(pedidos_pagos())
        self.assertEqual('CREATE VIEW IF NOT EXISTS "relatorios"."v_pagos" AS ' + SELECT_SQL, str(q))

    def test_temporary(self):
        q = Query.create_view("v").temporary().as_select(Query.from_("t").select("a"))
        self.assertEqual('CREATE TEMPORARY VIEW "v" AS SELECT "a" FROM "t"', str(q))

    def test_or_replace_temporary_order(self):
        q = Query.create_view("v").temporary().or_replace().as_select(Query.from_("t").select("a"))
        self.assertEqual('CREATE OR REPLACE TEMPORARY VIEW "v" AS SELECT "a" FROM "t"', str(q))

    def test_modifier_order_does_not_matter(self):
        q1 = Query.create_view("v").columns("x").if_not_exists().as_select(Query.from_("t").select("a"))
        q2 = Query.create_view("v").as_select(Query.from_("t").select("a")).if_not_exists().columns("x")
        self.assertEqual('CREATE VIEW IF NOT EXISTS "v" ("x") AS SELECT "a" FROM "t"', str(q1))
        self.assertEqual(str(q1), str(q2))

    def test_without_as_select_is_empty(self):
        self.assertEqual("", str(Query.create_view("v")))
        self.assertEqual("", str(Query.create_view("v").or_replace().columns("a")))

    def test_inner_query_renders_exactly_as_str(self):
        inner = Query.from_("t").select(Field("a").as_("b")).where(Field("c") > 1).orderby("a").limit(5)
        q = Query.create_view("v").as_select(inner)
        self.assertEqual('CREATE VIEW "v" AS ' + str(inner), str(q))


class HiddenCreateViewErrorsTests(unittest.TestCase):
    def test_as_select_requires_query_builder(self):
        with self.assertRaises(TypeError):
            Query.create_view("v").as_select("SELECT 1")

    def test_or_replace_then_if_not_exists(self):
        with self.assertRaises(QueryException):
            Query.create_view("v").or_replace().if_not_exists()

    def test_if_not_exists_then_or_replace(self):
        with self.assertRaises(QueryException):
            Query.create_view("v").if_not_exists().or_replace()

    def test_materialized_only_in_postgresql(self):
        with self.assertRaises(AttributeError):
            Query.create_view("v").materialized()
        with self.assertRaises(AttributeError):
            MySQLQuery.create_view("v").materialized()


class HiddenCreateViewDialectTests(unittest.TestCase):
    def test_mysql_backticks(self):
        q = MySQLQuery.create_view("v").as_select(MySQLQuery.from_("t").select("a"))
        self.assertEqual("CREATE VIEW `v` AS SELECT `a` FROM `t`", str(q))

    def test_mysql_inner_query_keeps_dialect_escaping(self):
        inner = MySQLQuery.from_("t").select("a").where(Field("path") == "c:\\tmp\\")
        q = MySQLQuery.create_view("v").or_replace().as_select(inner)
        self.assertEqual("CREATE OR REPLACE VIEW `v` AS " + str(inner), str(q))

    def test_postgresql_plain(self):
        q = PostgreSQLQuery.create_view("v").as_select(PostgreSQLQuery.from_("t").select("a"))
        self.assertEqual('CREATE VIEW "v" AS SELECT "a" FROM "t"', str(q))

    def test_postgresql_materialized(self):
        q = PostgreSQLQuery.create_view("mv").materialized().as_select(PostgreSQLQuery.from_("t").select("a"))
        self.assertEqual('CREATE MATERIALIZED VIEW "mv" AS SELECT "a" FROM "t"', str(q))

    def test_postgresql_materialized_with_columns_and_if_not_exists(self):
        q = (
            PostgreSQLQuery.create_view("mv")
            .materialized()
            .if_not_exists()
            .columns("x")
            .as_select(PostgreSQLQuery.from_("t").select("a"))
        )
        self.assertEqual('CREATE MATERIALIZED VIEW IF NOT EXISTS "mv" ("x") AS SELECT "a" FROM "t"', str(q))

    def test_postgresql_materialized_conflicts(self):
        with self.assertRaises(QueryException):
            PostgreSQLQuery.create_view("mv").materialized().or_replace()
        with self.assertRaises(QueryException):
            PostgreSQLQuery.create_view("mv").or_replace().materialized()
        with self.assertRaises(QueryException):
            PostgreSQLQuery.create_view("mv").materialized().temporary()
        with self.assertRaises(QueryException):
            PostgreSQLQuery.create_view("mv").temporary().materialized()


class HiddenCreateViewImmutabilityTests(unittest.TestCase):
    def test_modifiers_return_new_builders(self):
        base = Query.create_view("v")
        base.or_replace()
        base.temporary()
        base.columns("x")
        self.assertEqual('CREATE VIEW "v" AS SELECT 1', str(base.as_select(Query.select(1))))

    def test_columns_branches_are_independent(self):
        base = Query.create_view("v").columns("a")
        b1 = base.columns("b").as_select(Query.select(1))
        b2 = base.columns("c").as_select(Query.select(1))
        self.assertEqual('CREATE VIEW "v" ("a","b") AS SELECT 1', str(b1))
        self.assertEqual('CREATE VIEW "v" ("a","c") AS SELECT 1', str(b2))


if __name__ == "__main__":
    unittest.main()
