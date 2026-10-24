import json
import subprocess
import unittest
from unittest.mock import patch
import legacy_test_postgres as subject


class PrivateLegacyPostgresDestinationTest(unittest.TestCase):
    def environment(self):
        return {"UTEN_LEGACY_TEST_PG_CONTAINER": "a" * 64,
                "UTEN_LEGACY_TEST_PG_DATABASE": "legacy_bootstrap_rehearsal",
                "UTEN_LEGACY_TEST_PG_USER": "fixture_admin",
                "UTEN_LEGACY_TEST_PG_NONCE": "77777777-7777-4777-8777-777777777777"}

    def test_missing_named_or_business_destinations_fail_before_any_process(self):
        for change in [None, {"UTEN_LEGACY_TEST_PG_CONTAINER": "uten-imp-postgres"},
                       {"UTEN_LEGACY_TEST_PG_DATABASE": "uten_imp"},
                       {"UTEN_LEGACY_TEST_PG_NONCE": ""}]:
            env = {} if change is None else {**self.environment(), **change}
            with self.subTest(change=change), patch.dict(subject.os.environ, env, clear=True), \
                    patch.object(subject.subprocess, "run") as run:
                with self.assertRaises(RuntimeError): subject.fixture_psql("BEGIN; SELECT 1; ROLLBACK;")
                run.assert_not_called()

    def test_foreign_container_label_cannot_receive_sql(self):
        result = subprocess.CompletedProcess([], 0, json.dumps({"org.testcontainers": "true",
                                           "uten.imp.legacy.fixture": "foreign"}), "")
        with patch.dict(subject.os.environ, self.environment(), clear=True), \
                patch.object(subject.subprocess, "run", return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, "not this coordinator"):
                subject.fixture_psql("BEGIN; SELECT 1; ROLLBACK;")
            self.assertEqual(1, run.call_count)

    def test_valid_owned_immutable_id_is_forwarded_without_a_name_fallback(self):
        labels = {"org.testcontainers": "true", "uten.imp.legacy.fixture": self.environment()["UTEN_LEGACY_TEST_PG_NONCE"]}
        inspected = subprocess.CompletedProcess([], 0, json.dumps(labels), "")
        executed = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.dict(subject.os.environ, self.environment(), clear=True), \
                patch.object(subject.subprocess, "run", side_effect=[inspected, executed]) as run:
            self.assertIs(executed, subject.fixture_psql("BEGIN; SELECT 1; ROLLBACK;"))
            command = run.call_args.args[0]
            self.assertEqual("a" * 64, command[3])
            self.assertNotIn("uten-imp-postgres", command)
            self.assertIn("legacy_bootstrap_rehearsal", command)


if __name__ == "__main__": unittest.main()
