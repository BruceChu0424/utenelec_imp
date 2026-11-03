"""Run the real goods-price SQL guards against an explicitly owned private PG.

Every case owns a rollback-only transaction and creates temporary tables only.
No development/business database or named-container fallback is permitted.
"""
import os
from pathlib import Path
import re
import unittest

from legacy_test_postgres import fixture_psql


HERE = Path(__file__).resolve().parent
FIXTURE_ENV = ("UTEN_LEGACY_TEST_PG_CONTAINER", "UTEN_LEGACY_TEST_PG_DATABASE",
               "UTEN_LEGACY_TEST_PG_USER", "UTEN_LEGACY_TEST_PG_NONCE")
PRICE_COLUMNS = ("price", "a_price", "price2")


def literal(value):
    return "NULL" if value is None else "'" + str(value).replace("'", "''") + "'"


def check_sql(condition, message):
    return ("DO $fixture_assert$ BEGIN IF NOT (" + condition + ") THEN RAISE EXCEPTION "
            + literal(message) + "; END IF; END $fixture_assert$;\n")


@unittest.skipUnless(all(os.environ.get(name) for name in FIXTURE_ENV),
                     "set the four UTEN_LEGACY_TEST_PG_* variables for an owned private PostgreSQL fixture")
class LegacyGoodsPricePrecisionPostgresTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (HERE / "migrate_goods_data.sql").read_text(encoding="utf-8")
        cls.stage_ddl = re.search(r"CREATE TEMP TABLE goods_stage\s*\([\s\S]*?\n\);", source)[0]
        cls.preflight = re.search(r"DO \$price_precision\$[\s\S]*?END \$price_precision\$;", source)[0]
        cls.reconciliation = re.search(r"DO \$price_reconciliation\$[\s\S]*?END \$price_reconciliation\$;", source)[0]
        start = source.index(cls.preflight)
        delete_end = source.index("DELETE FROM goods;", start) + len("DELETE FROM goods;")
        cls.preflight_and_delete = source[start:delete_end]

    def run_sql(self, body):
        result = fixture_psql("BEGIN;\n" + body + "\nSELECT 'GOODS_PRICE_FIXTURE_PASSED';\nROLLBACK;")
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        self.assertIn("GOODS_PRICE_FIXTURE_PASSED", result.stdout.decode("utf-8", errors="replace"))

    def setup_sql(self, target_type="numeric(18,4)", *, column_types=None):
        types = dict.fromkeys(PRICE_COLUMNS, target_type)
        types.update(column_types or {})
        columns = ", ".join(column + " " + types[column] for column in PRICE_COLUMNS)
        return ("CREATE TEMP TABLE goods (id integer PRIMARY KEY, legacy_id integer UNIQUE, " + columns + ");\n"
                + self.stage_ddl + "\n")

    def stage_row(self, identity, values):
        return ("INSERT INTO goods_stage (legacy_id,price,a_price,price2) VALUES (" + str(identity) + ","
                + ",".join(literal(value) for value in values) + ");\n")

    def insert_prices(self):
        return ("INSERT INTO goods (id,legacy_id,price,a_price,price2) "
                "SELECT legacy_id,legacy_id,price,a_price,price2 FROM goods_stage;\n")

    def expected_rejection(self, body, message):
        # The unexpected-success exception has a different SQLSTATE so this
        # block cannot catch its own assertion and accidentally pass the test.
        return ("DO $fixture_rejection$ DECLARE failure text; BEGIN BEGIN\n" + body
                + "\nRAISE EXCEPTION USING ERRCODE='UT001', MESSAGE='price guard unexpectedly accepted fixture';\n"
                  "EXCEPTION WHEN SQLSTATE 'P0001' THEN GET STACKED DIAGNOSTICS failure=MESSAGE_TEXT;\n"
                  "IF strpos(failure," + literal(message) + ")=0 THEN RAISE; END IF;\n"
                  "END; END $fixture_rejection$;\n")

    def protect_original_from_delete(self):
        # This trigger proves the rejecting preflight ran before DELETE, even
        # though an exception subtransaction would also roll back an early delete.
        return ("INSERT INTO goods(id,legacy_id,price,a_price,price2) VALUES (999,999,7,8,9);\n"
                "CREATE FUNCTION pg_temp.reject_early_price_delete() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN\n"
                "RAISE EXCEPTION USING ERRCODE='UT002', MESSAGE='DELETE reached before price rejection'; END $$;\n"
                "CREATE TRIGGER reject_early_delete BEFORE DELETE ON goods FOR EACH STATEMENT "
                "EXECUTE FUNCTION pg_temp.reject_early_price_delete();\n")

    def test_real_staging_keeps_all_three_prices_as_unlimited_exact_numeric(self):
        sql = self.setup_sql()
        sql += self.stage_row(17, ("0.9141234567", "1.0000000001", "9876543.1234567890"))
        for column, value in zip(PRICE_COLUMNS, ("0.9141234567", "1.0000000001", "9876543.1234567890")):
            sql += check_sql("(SELECT atttypid='numeric'::regtype AND atttypmod=-1 FROM pg_attribute "
                             "WHERE attrelid='goods_stage'::regclass AND attname=" + literal(column) + ")",
                             "staging must not cast a price through float or a fixed scale")
            sql += check_sql("(SELECT " + column + "::text FROM goods_stage WHERE legacy_id=17)=" + literal(value),
                             "staging changed exact source price")
        self.run_sql(sql)

    def test_fixed_scale_accepts_exact_prices_zero_null_and_redundant_trailing_zeroes(self):
        sql = self.setup_sql() + "INSERT INTO goods VALUES (999,999,7,8,9);\n"
        for identity, values in enumerate((("0.914", "0", "0.9140000000"),
                                            ("0.0000000000", "3.0000", "12.1234"),
                                            (None, None, None)), 1):
            sql += self.stage_row(identity, values)
        sql += self.preflight_and_delete + "\n" + self.insert_prices() + self.reconciliation + "\n"
        sql += check_sql("(SELECT count(*) FROM goods)=3 AND NOT EXISTS(SELECT 1 FROM goods WHERE legacy_id=999)",
                         "exact compatible rows must replace the old master")
        sql += check_sql("(SELECT price=0.914 AND a_price=0 AND price2=0.914 FROM goods WHERE legacy_id=1)",
                         "compatible decimal values must remain exact")
        self.run_sql(sql)

    def test_each_overprecision_price_rejects_before_delete_and_preserves_original_goods(self):
        for column in PRICE_COLUMNS:
            with self.subTest(column=column):
                values = {name: "0" for name in PRICE_COLUMNS}
                values[column] = "0.9141234567"
                sql = self.setup_sql() + self.protect_original_from_delete()
                sql += self.stage_row(17, [values[name] for name in PRICE_COLUMNS])
                sql += self.expected_rejection(self.preflight_and_delete, "without rounding/truncation: " + column)
                sql += check_sql("(SELECT count(*) FROM goods WHERE legacy_id=999 AND price=7 AND a_price=8 AND price2=9)=1",
                                 "rejected source must preserve the complete original goods row")
                self.run_sql(sql)

    def test_unlimited_numeric_import_preserves_high_precision_in_all_three_prices(self):
        values = ("0.9141234567", "1.0000000001", "9876543.1234567890")
        sql = self.setup_sql("numeric") + self.stage_row(17, values)
        sql += self.preflight_and_delete + "\n" + self.insert_prices() + self.reconciliation + "\n"
        for column, value in zip(PRICE_COLUMNS, values):
            sql += check_sql("(SELECT " + column + "::text FROM goods WHERE legacy_id=17)=" + literal(value),
                             "unlimited numeric target changed a source decimal")
        self.run_sql(sql)

    def test_nonfinite_sources_are_rejected_for_every_price_before_delete(self):
        for column in PRICE_COLUMNS:
            for nonfinite in ("NaN", "Infinity", "-Infinity"):
                with self.subTest(column=column, nonfinite=nonfinite):
                    values = {name: "0" for name in PRICE_COLUMNS}
                    values[column] = nonfinite
                    sql = self.setup_sql("numeric") + self.protect_original_from_delete()
                    sql += self.stage_row(17, [values[name] for name in PRICE_COLUMNS])
                    sql += self.expected_rejection(self.preflight_and_delete, "without rounding/truncation: " + column)
                    sql += check_sql("(SELECT count(*) FROM goods WHERE legacy_id=999)=1", "nonfinite price erased original goods")
                    self.run_sql(sql)

    def test_non_numeric_target_columns_are_rejected_before_delete(self):
        for column in PRICE_COLUMNS:
            for target in ("double precision", "text"):
                with self.subTest(column=column, target=target):
                    sql = self.setup_sql("numeric", column_types={column: target}) + self.protect_original_from_delete()
                    sql += self.stage_row(17, ("0.914", "0", "2"))
                    sql += self.expected_rejection(self.preflight_and_delete, "Goods price target must be exact numeric: " + column)
                    sql += check_sql("(SELECT count(*) FROM goods WHERE legacy_id=999)=1", "inexact target erased original goods")
                    self.run_sql(sql)

    def test_post_import_guard_rejects_a_trigger_changing_any_price(self):
        for column in PRICE_COLUMNS:
            with self.subTest(column=column):
                sql = self.setup_sql("numeric") + self.stage_row(17, ("0.9141234567", "1.0000000001", "2.1234567890"))
                sql += self.preflight_and_delete + "\n"
                sql += ("CREATE FUNCTION pg_temp.change_imported_price() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW."
                        + column + " := NEW." + column + "+0.0000000001; RETURN NEW; END $$;\n"
                        "CREATE TRIGGER change_price BEFORE INSERT ON goods FOR EACH ROW "
                        "EXECUTE FUNCTION pg_temp.change_imported_price();\n")
                sql += self.insert_prices()
                sql += self.expected_rejection(self.reconciliation, "Goods price changed during import")
                self.run_sql(sql)

    def test_post_import_guard_rejects_missing_goods_or_a_price_changed_to_null(self):
        for change in ("DELETE FROM goods WHERE legacy_id=17;", "UPDATE goods SET a_price=NULL WHERE legacy_id=17;"):
            with self.subTest(change=change):
                sql = self.setup_sql("numeric") + self.stage_row(17, ("0.914", "1", "2"))
                sql += self.preflight_and_delete + "\n" + self.insert_prices() + change + "\n"
                sql += self.expected_rejection(self.reconciliation, "Goods price changed during import")
                self.run_sql(sql)


if __name__ == "__main__":
    unittest.main()
