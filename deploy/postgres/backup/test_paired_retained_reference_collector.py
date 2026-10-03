"""Pure metadata fixtures. No Docker, DB, credentials or storage mutation."""
import hashlib
import importlib.util
from pathlib import Path
import sys
import uuid
import unittest

SOURCE = Path(__file__).with_name("paired_internal_backup.py")
SPEC = importlib.util.spec_from_file_location("paired_retained_candidate", SOURCE)
PAIRED = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PAIRED
SPEC.loader.exec_module(PAIRED)
DIGEST = hashlib.sha256(b"original").hexdigest()


def reference(number):
    return (str(uuid.UUID(int=number)), "local", f"{number:032x}.pdf", None, 8, DIGEST)


class Cursor:
    def __init__(self, private=None, attachments=(), view=True, deletion=None):
        self.private = private or {}
        self.attachments = attachments
        self.view = view
        self.deletion = deletion
        self.queries = []
        self.result = []
    def execute(self, sql, args=()):
        self.queries.append(sql)
        if sql.startswith("SELECT to_regclass"):
            table = args[0].split(".")[-1] if args else "v_private_document_storage_references"
            self.result = [(table if (table in self.private or (table.startswith("v_private") and self.view)) else None,)]
        elif "information_schema.columns" in sql:
            self.result = [(True,)]
        elif "FROM attachments " in sql:
            self.result = list(self.attachments)
        elif "FROM public." in sql:
            table = sql.split("FROM public.", 1)[1].split()[0]
            self.result = list(self.private[table])
        elif "FROM v_private_document_storage_references" in sql:
            self.result = [(row[1], row[2], row[3]) for rows in self.private.values() for row in rows]
        elif "FROM attachment_object_outbox" in sql:
            accepted = ("SUCCEEDED", "RETAINED_HISTORY") if "NOT IN ('SUCCEEDED','RETAINED_HISTORY')" in sql else ("SUCCEEDED",)
            self.result = [(self.deletion is not None and self.deletion not in accepted,)]
        else:
            raise AssertionError(sql)
    def fetchone(self):
        return self.result[0]
    def fetchall(self):
        return self.result


class RetainedReferenceCollectorTest(unittest.TestCase):
    def test_all_current_external_sources_and_retained_attachments_are_enumerated_without_blobs(self):
        attachment = (str(uuid.UUID(int=101)), "GOODS", str(uuid.UUID(int=201)), f"{1:032x}.pdf", None, DIGEST, 8, None, None, "local")
        private = {"goods_cost_imports": [reference(2)], "sales_quote_template_versions": [(str(uuid.UUID(int=3))+":1", *reference(3)[1:])],
                   "sales_quote_template_candidates": [], "sales_quote_template_candidate_history": [(4, *reference(4)[1:])],
                   "ai_input_originals": [reference(5)]}
        cursor = Cursor(private, [attachment])
        rows = PAIRED.collect_references(cursor)
        self.assertEqual({row["source_table"] for row in rows}, {"attachments", "goods_cost_imports",
                         "sales_quote_template_versions", "sales_quote_template_candidate_history", "ai_input_originals"})
        self.assertEqual(len(rows), 5)
        self.assertTrue(any("'RETAINED_HISTORY'" in sql and "'DELETE_PENDING'" in sql for sql in cursor.queries))
        ai = next(sql for sql in cursor.queries if "FROM public.ai_input_originals" in sql)
        self.assertIn("SELECT job_id,", ai)
        self.assertIn("availability='AVAILABLE' AND lifecycle_state='AVAILABLE'", ai)
        self.assertFalse(any("legacy_bytes" in sql or "SELECT payload," in sql or "SELECT *" in sql for sql in cursor.queries))
        history = next(sql for sql in cursor.queries if "FROM public.sales_quote_template_candidate_history" in sql)
        self.assertIn("(payload->>'storage_size')::bigint", history)
        versions = next(sql for sql in cursor.queries if "FROM public.sales_quote_template_versions" in sql)
        self.assertIn("template_id::text||':'||version::text", versions)
    def test_old_pre_private_schema_still_collects_clean_originals(self):
        attachment = (str(uuid.UUID(int=101)), "GOODS", str(uuid.UUID(int=201)), f"{6:032x}.pdf", None, DIGEST, 8, None, None, "local")
        rows = PAIRED.collect_references(Cursor(attachments=[attachment], view=False))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["source_table"], "attachments")
    def test_retained_deletion_fact_is_not_a_physical_delete_but_pending_task_still_blocks(self):
        row = {"source_table": "attachments", "id": str(uuid.UUID(int=301)), "storage_provider": "local", "storage_key": f"{7:032x}.pdf",
               "storage_version": None, "size_bytes": 8, "sha256": DIGEST}
        PAIRED.assert_reference_consistency(Cursor(deletion="RETAINED_HISTORY"), [row])
        with self.assertRaisesRegex(ValueError, "pending physical-delete"):
            PAIRED.assert_reference_consistency(Cursor(deletion="PROCESSING"), [row])
    def test_malformed_version_or_history_identity_fails_closed(self):
        for table, identity in [("sales_quote_template_versions", "bad:1"), ("sales_quote_template_versions", str(uuid.UUID(int=9))+":0"), ("sales_quote_template_candidate_history", "0")]:
            row = {"source_table": table, "id": identity, "storage_provider": "local", "storage_key": f"{9:032x}.pdf", "storage_version": None, "size_bytes": 8, "sha256": DIGEST}
            with self.assertRaisesRegex(ValueError, "Invalid logical"):
                PAIRED.normalize_reference(row)
    def test_current_one_cost_original_has_unchanged_identity(self):
        cursor = Cursor({"goods_cost_imports": [reference(8)]})
        rows = PAIRED.collect_references(cursor)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["storage_key"], f"{8:032x}.pdf")
        self.assertEqual(rows[0]["sha256"], DIGEST)
        self.assertEqual(rows[0]["size_bytes"], 8)


if __name__ == "__main__":
    unittest.main()
