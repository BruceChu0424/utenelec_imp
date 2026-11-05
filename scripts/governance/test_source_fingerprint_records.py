import copy
import unittest

from source_fingerprint_records import encode, source_records


class SourceFingerprintRecordsTest(unittest.TestCase):
    def test_source_paths_and_sha256_remain_exact_but_have_distinct_json_fields(self):
        source = {"server/features/ReceiptSourceAccess.java": "a" * 64}
        result, count = source_records(source, "sha256")
        self.assertEqual(1, count)
        self.assertEqual({path: {"algorithm": "sha256", "digest": digest} for path, digest in source.items()}, result)

    def test_historical_git_blob_ids_keep_their_actual_algorithm(self):
        result, count = source_records({"server/SourceAccess.java": "b" * 40}, "git-blob-sha1")
        self.assertEqual(1, count)
        self.assertEqual("git-blob-sha1", result["server/SourceAccess.java"]["algorithm"])
        self.assertEqual("b" * 40, result["server/SourceAccess.java"]["digest"])

    def test_representation_change_preserves_outcomes_scope_and_historical_timestamps(self):
        original = {"recordedAtUtc": "2026-11-04T00:00:00Z", "passed": False, "sourceSha256": {"lib/access.dart": "c" * 64},
                    "runs": [{"failures": 3, "skipped": 4}], "localTaskCommit": "original"}
        snapshot = copy.deepcopy(original)
        result, count = encode(original)
        self.assertEqual(snapshot, original)
        self.assertEqual(1, count)
        for field in ("recordedAtUtc", "passed", "runs", "localTaskCommit"):
            self.assertEqual(original[field], result[field])

    def test_reencoding_is_idempotent(self):
        once, _ = encode({"sourceSha256": {"lib/access.dart": "d" * 64}})
        twice, count = encode(once)
        self.assertEqual(once, twice)
        self.assertEqual(0, count)

    def test_unrelated_credential_fields_are_never_reclassified_or_redacted(self):
        original = {"api_key": "example", "nested": {"token": "unchanged"}}
        result, count = encode(original)
        self.assertEqual(original, result)
        self.assertEqual(0, count)

    def test_malformed_source_records_fail_instead_of_hiding_unknown_values(self):
        for source in ({"api_key": "a" * 64}, {"../source.java": "a" * 64}, {"server/source.java": "not-a-hash"}):
            with self.assertRaises(ValueError):
                source_records(source, "sha256")
        with self.assertRaises(ValueError):
            source_records({"server/source.java": {"algorithm": "git-blob-sha1", "digest": "a" * 40}}, "sha256")


if __name__ == "__main__":
    unittest.main()
