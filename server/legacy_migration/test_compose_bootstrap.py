"""Lexer and byte-preservation contracts for the shipped import composer."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("bootstrap_composer", HERE / "compose_bootstrap.py")
composer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = composer
SPEC.loader.exec_module(composer)


class BootstrapComposerTest(unittest.TestCase):
    def assert_preserved(self, sql):
        content = sql if isinstance(sql, bytes) else sql.encode("utf-8")
        output = composer.compose(content, "fixture.sql")
        marker = b"\\echo Bootstrap module: fixture.sql\n"
        self.assertTrue(output.startswith(marker))
        self.assertEqual(output[len(marker):len(marker) + len(content)], content)
        return output[len(marker) + len(content):]

    def assert_rejected(self, sql):
        with self.assertRaises(ValueError):
            composer.compose(sql.encode("utf-8"), "fixture.sql")

    def test_every_current_loader_has_explicit_caller_owned_transactions(self):
        files = sorted(HERE.glob("migrate_*.sql"))
        self.assertGreater(len(files), 25)
        for source in files:
            with self.subTest(source=source.name):
                original = source.read_bytes()
                result = composer.compose(original, source.name)
                marker = f"\\echo Bootstrap module: {source.name}\n".encode()
                self.assertEqual(result[len(marker):len(marker) + len(original)], original)

    def test_crlf_unicode_strings_identifiers_and_nested_comments_are_byte_exact(self):
        sql = ("-- Unicode 注释 COMMIT;\r\n"
               "SELECT 'BEGIN; ''COMMIT''; ROLLBACK', \"END\" FROM \"BEGIN\";\r\n"
               "/* outer BEGIN; /* inner COMMIT; */ END; */\r\n"
               "SELECT $text$BEGIN; 'unclosed quote; \\connect other\nCOMMIT;$text$;\r\n"
               "DO $program$ BEGIN RAISE NOTICE 'COMMIT;'; END $program$;\r\n")
        self.assert_preserved(sql)

    def test_escape_strings_and_doubled_identifier_quotes_are_not_commands(self):
        self.assert_preserved(r'''SELECT E'escaped \' quote; COMMIT;', "COMMIT""END";''')
        self.assert_preserved(r"SELECT 'standard backslash \\';")
        self.assert_preserved("SELECT value$tag$ FROM some_table;")

    def test_any_casing_indentation_or_interleaved_comments_cannot_end_the_transaction(self):
        commands = ["bEgIn", "BEGIN WORK", "begin transaction", "START /* boundary */ TRANSACTION",
                    "CoMmIt AND CHAIN", "commit work", "END", "end transaction", "ROLLBACK TO SAVEPOINT x",
                    "ABORT", "SAVEPOINT x", "RELEASE x", "RELEASE SAVEPOINT x",
                    "PREPARE /* boundary */ TRANSACTION 'prepared'", "SET TRANSACTION READ ONLY",
                    "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE"]
        for command in commands:
            with self.subTest(command=command):
                self.assert_rejected("SELECT 1;\n\t /* outer /* nested */ */ " + command + ";\n")

    def test_carriage_return_comments_cannot_hide_transaction_control(self):
        for ending in ("\n", "\r", "\r\n"):
            with self.subTest(ending=repr(ending)):
                self.assert_rejected("-- comment" + ending + "  COMMIT;")

    def test_on_commit_drop_and_case_end_are_sql_syntax_not_transaction_commands(self):
        self.assert_preserved("CREATE TEMP TABLE stage(id int) ON COMMIT DROP; SELECT CASE WHEN TRUE THEN 1 END;")
        self.assert_preserved('CREATE TABLE "function" ("COMMIT" text);')
        self.assert_preserved("DO $$ BEGIN CREATE TEMP TABLE stage(id int) ON COMMIT DROP; END $$;")

    def test_direct_procedural_transaction_commands_are_rejected_without_rewriting(self):
        for body in ("BEGIN COMMIT; END", "BEGIN IF TRUE THEN cOmMiT AND CHAIN; END IF; END",
                     "BEGIN PERFORM 1; ROLLBACK; END", "BEGIN SAVEPOINT point; END",
                     "BEGIN LOOP RELEASE SAVEPOINT point; END LOOP; END",
                     "BEGIN START TRANSACTION; END", "BEGIN SET TRANSACTION READ ONLY; END"):
            with self.subTest(body=body):
                self.assert_rejected("DO $procedure$ " + body + " $procedure$;")
        self.assert_rejected("DO $程序$ BEGIN COMMIT; END $程序$;")
        self.assert_rejected("DO 'BEGIN COMMIT; END';")

    def test_function_and_procedure_programs_use_the_same_control_guard(self):
        for prefix in ("CREATE FUNCTION f() RETURNS void", "CREATE OR REPLACE FUNCTION f() RETURNS void",
                       "CREATE PROCEDURE f()", "CREATE OR REPLACE PROCEDURE f()"):
            with self.subTest(prefix=prefix):
                self.assert_rejected(prefix + " LANGUAGE plpgsql AS $$ BEGIN COMMIT; END $$;")
                self.assert_preserved(prefix + " LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE 'COMMIT'; END $$;")

    def test_procedural_quoted_and_nested_dollar_values_remain_literal_data(self):
        self.assert_preserved("DO $outer$ BEGIN PERFORM $inner$COMMIT; \\connect other$inner$; "
                              "RAISE NOTICE 'ROLLBACK;'; END $outer$;")
        self.assert_preserved("DO $outer$ BEGIN /* COMMIT /* nested */ END; */ "
                              "PERFORM \"COMMIT\" FROM records; END $outer$;")
        self.assert_preserved("SELECT $tag$COMMIT; ROLLBACK; BEGIN;$tag$;")

    def test_dollar_delimiters_are_case_sensitive_and_malformed_quotes_fail_closed(self):
        for sql in ("SELECT 'unfinished;", 'SELECT "unfinished;', "SELECT $tag$unfinished$TAG$;",
                    "/* outer /* inner */", "SELECT E'backslash\\", "SELECT 1"):
            with self.subTest(sql=sql):
                self.assert_rejected(sql)

    def test_only_static_reviewed_csv_copy_and_key_include_are_allowed(self):
        self.assert_preserved("  \\copy stage(legacy_id, name) FROM '/tmp/goods.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)\r\n"
                              "\\copy categories FROM '/tmp/goods_categories.csv' WITH (FORMAT text, DELIMITER '|', HEADER true)\n"
                              "\\i :legacy_key_file\n")

    def test_psql_connection_shell_execution_and_dynamic_file_commands_are_rejected(self):
        commands = [r"\connect another", r"\c another", r"\gexec", r"\gset", r"\! touch /tmp/file",
                    r"\set AUTOCOMMIT on", r"\unset ON_ERROR_STOP", r"\quit", r"\ir elsewhere.sql",
                    r"\i '/tmp/other.sql'", r"\i :other_file", r"\include :legacy_key_file",
                    r"\copy stage FROM PROGRAM 'echo text'", r"\copy stage FROM stdin",
                    r"\copy stage FROM :file WITH (FORMAT csv, DELIMITER '|', HEADER true)",
                    r"\copy stage FROM '/tmp/../secret.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)",
                    r"\copy stage FROM '/tmp/goods.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true) \\ \connect other"]
        for command in commands:
            with self.subTest(command=command):
                self.assert_rejected(command + "\n")
        self.assert_rejected("SELECT 1 \\gexec\n")
        self.assert_rejected("SELECT 1; \\i :legacy_key_file\n")

    def test_cleanup_preserves_only_the_exact_shared_evidence_tables(self):
        suffix = self.assert_preserved("SELECT 1;\n").decode()
        self.assertEqual(composer.PRESERVED_TEMP_TABLES, (
            "bootstrap_source_master_ids", "bootstrap_legacy_reference_evidence", "bootstrap_bom_exclusions"))
        for table in composer.PRESERVED_TEMP_TABLES:
            self.assertIn("'" + table + "'", suffix)
        self.assertIn("relnamespace=pg_my_temp_schema()", suffix)
        self.assertNotIn("LIKE 'bootstrap_%'", suffix)
        self.assertIn("DROP TABLE pg_temp.%I", suffix)

    def test_cli_rejects_before_emitting_any_partial_module(self):
        with tempfile.TemporaryDirectory(prefix="uten-composer-") as directory:
            folder = pathlib.Path(directory).resolve()
            self.assertEqual(folder.parent, pathlib.Path(tempfile.gettempdir()).resolve())
            source = folder / "fixture.sql"
            source.write_bytes(b"SELECT 'sensitive fixture text';\nCOMMIT;\n")
            result = subprocess.run([sys.executable, str(HERE / "compose_bootstrap.py"), str(source)], capture_output=True)
            self.assertEqual(result.returncode, 66)
            self.assertEqual(result.stdout, b"")
            self.assertNotIn(b"sensitive fixture text", result.stderr)


if __name__ == "__main__":
    unittest.main()
