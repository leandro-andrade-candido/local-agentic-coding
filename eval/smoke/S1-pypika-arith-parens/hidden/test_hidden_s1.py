"""Testes ocultos do S1: parênteses do lado direito de uma subtração."""
import unittest

from pypika import Field as F, Query as Q, Table


class HiddenSubtractionParenthesesTests(unittest.TestCase):
    t = Table("abc")

    def test__complex_op_sub_parentheses(self):
        # Teste original do upstream (removido da suíte visível).
        q1 = Q.from_("abc").select((F("a") + 1) - (F("b") - 5))
        q2 = Q.from_(self.t).select((self.t.a + 1) - (self.t.b - 5))
        q3 = Q.from_("abc").select((F("a") / 1) - (F("b") / 5))
        self.assertEqual('SELECT "a"+1-("b"-5) FROM "abc"', str(q1))
        self.assertEqual('SELECT "a"+1-("b"-5) FROM "abc"', str(q2))
        self.assertEqual('SELECT "a"/1-"b"/5 FROM "abc"', str(q3))

    def test_sub_of_sum_keeps_parentheses(self):
        q = Q.from_("contas").select((F("receita") - (F("custo") + F("imposto"))).as_("saldo"))
        self.assertEqual('SELECT "receita"-("custo"+"imposto") "saldo" FROM "contas"', str(q))

    def test_add_and_mul_unchanged(self):
        self.assertEqual('"a"+"b"-"c"', str(F("a") + F("b") - F("c")))
        self.assertEqual('"a"*("b"+"c")', str(F("a") * (F("b") + F("c"))))
        self.assertEqual('"a"/("b"*"c")', str(F("a") / (F("b") * F("c"))))
        self.assertEqual('"a"-"b"*"c"', str(F("a") - F("b") * F("c")))


if __name__ == "__main__":
    unittest.main()
