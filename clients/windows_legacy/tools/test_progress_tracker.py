import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import progress_tracker as tracker


class ProgressTrackerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wpf progress fixture ")
        self.root = Path(self.temporary.name).resolve()
        self.state = self.root / "clients/windows_legacy/progress"
        self.state.mkdir(parents=True)
        (self.root / "evidence.md").write_text("source-owned fixture evidence", encoding="utf-8")
        self.patches = [mock.patch.object(tracker, "ROOT", self.root), mock.patch.object(tracker, "STATE", self.state)]
        for patch in self.patches:
            patch.start()

    def tearDown(self):
        for patch in reversed(self.patches):
            patch.stop()
        self.temporary.cleanup()

    def task(self, identifier="W7-ONE-001", status="todo", dependencies=None):
        return {"id": identifier, "title": identifier, "status": status, "group": "ONE", "owner": "fixture",
                "sources": [], "nativeTargets": [], "definitionOfDone": ["fixture specific acceptance"],
                "dependencies": dependencies or [], "evidence": ["evidence.md"] if status == "done" else [],
                "notes": "", "lastUpdated": "2026-10-28"}

    def source_inputs(self, pages):
        (self.state / "business-inventory.json").write_text(json.dumps({"pages": pages, "featureGroups": []}), encoding="utf-8")
        (self.state / "infrastructure-catalog.json").write_text(json.dumps({"tasks": [], "groups": []}), encoding="utf-8")

    def page(self, name, digest="a" * 64):
        return {"source": "lib/features/fixture/pages/" + name + "_page.dart", "feature": "fixture", "sha256": digest, "actionHandlers": []}

    def test_done_requires_review_and_real_evidence(self):
        registry = {"tasks": [self.task()]}
        with self.assertRaisesRegex(ValueError, "acceptance-reviewed"):
            tracker.change_status(registry, "W7-ONE-001", "done", "", "", [], False)
        with self.assertRaisesRegex(ValueError, "does not exist"):
            tracker.change_status(registry, "W7-ONE-001", "done", "", "", ["missing.md"], True)
        tracker.change_status(registry, "W7-ONE-001", "done", "reviewer", "reviewed", ["evidence.md"], True)
        self.assertEqual("done", registry["tasks"][0]["status"])
        self.assertEqual("reviewer", registry["tasks"][0]["owner"])

    def test_cannot_complete_with_open_dependency(self):
        registry = {"tasks": [self.task(), self.task("W7-TWO-001", dependencies=["W7-ONE-001"])]}
        with self.assertRaisesRegex(ValueError, "prerequisites"):
            tracker.change_status(registry, "W7-TWO-001", "done", "", "", ["evidence.md"], True)

    def test_na_is_not_a_way_to_hide_unimplemented_work(self):
        registry = {"tasks": [self.task()]}
        with self.assertRaises(ValueError):
            tracker.change_status(registry, "W7-ONE-001", "not_applicable", "", "", [], False)
        with self.assertRaisesRegex(ValueError, "source evidence"):
            tracker.change_status(registry, "W7-ONE-001", "not_applicable", "", "retired source confirmed", [], False)

    def test_stable_page_ids_do_not_renumber_when_earlier_page_is_added(self):
        self.source_inputs([self.page("z")])
        previous = tracker.build_registry()
        prior = previous["tasks"][0]
        prior["status"] = "implemented"
        prior["notes"] = "specific handover"
        prior["title"] = "人工核实的页面标题"
        self.source_inputs([self.page("a"), self.page("z")])
        updated = tracker.build_registry(previous)
        z = next(item for item in updated["tasks"] if item["businessSource"].endswith("z_page.dart"))
        a = next(item for item in updated["tasks"] if item["businessSource"].endswith("a_page.dart"))
        self.assertEqual(prior["id"], z["id"])
        self.assertNotEqual(a["id"], z["id"])
        self.assertEqual("specific handover", z["notes"])
        self.assertEqual("人工核实的页面标题", z["title"])

    def test_source_change_reopens_done_without_erasing_prior_evidence(self):
        self.source_inputs([self.page("a")])
        previous = tracker.build_registry()
        previous["tasks"][0].update(status="done", evidence=["evidence.md"])
        self.source_inputs([self.page("a", "b" * 64)])
        updated = tracker.build_registry(previous)
        self.assertEqual("in_progress", updated["tasks"][0]["status"])
        self.assertEqual(["evidence.md"], updated["tasks"][0]["evidence"])

    def test_removed_page_stays_visible_until_manual_scope_review(self):
        self.source_inputs([self.page("a"), self.page("b")])
        previous = tracker.build_registry()
        self.source_inputs([self.page("a")])
        updated = tracker.build_registry(previous)
        self.assertEqual(2, len(updated["tasks"]))
        b = next(item for item in updated["tasks"] if item["businessSource"].endswith("b_page.dart"))
        self.assertEqual("in_progress", b["status"])
        self.assertIn("不得自动删除", b["notes"])

    def test_dependency_evidence_change_reopens_done_even_when_page_bytes_match(self):
        first = self.page("a")
        first["directImports"] = [{"source": "repo.dart", "targetSha256": "a" * 64}]
        self.source_inputs([first])
        previous = tracker.build_registry()
        previous["tasks"][0].update(status="done", dependencies=[], evidence=["evidence.md"])
        second = copy.deepcopy(first)
        second["directImports"][0]["targetSha256"] = "b" * 64
        self.source_inputs([second])
        self.assertEqual("in_progress", tracker.build_registry(previous)["tasks"][0]["status"])

    def test_reopened_prerequisite_reopens_done_descendants_without_erasing_evidence(self):
        registry = {"tasks": [self.task("W7-A", "in_progress"), self.task("W7-B", "done", ["W7-A"]),
                              self.task("W7-C", "done", ["W7-B"])]}
        tracker.reopen_dependents(registry)
        self.assertEqual(["in_progress"] * 3, [item["status"] for item in registry["tasks"]])
        self.assertEqual(["evidence.md"], registry["tasks"][2]["evidence"])

    def test_rejects_cycles_and_evidence_escape(self):
        registry = {"tasks": [self.task("W7-ONE-001", dependencies=["W7-TWO-001"]), self.task("W7-TWO-001", dependencies=["W7-ONE-001"])]}
        with self.assertRaisesRegex(ValueError, "Cyclic"):
            tracker.validate(registry)
        with self.assertRaisesRegex(ValueError, "repository-relative"):
            tracker.relative_file("../outside.md")

    def test_summary_does_not_count_implemented_or_local_as_completed(self):
        registry = {"tasks": [self.task("W7-A", "done"), self.task("W7-B", "implemented"), self.task("W7-C", "verified_local")]}
        self.assertEqual(1, tracker.summary(registry)["done"])
        self.assertEqual(2, tracker.summary(registry)["remainingIncludingUnverified"])

    def test_failed_registry_replace_preserves_previous_progress_and_cleans_only_own_temp(self):
        target = self.state / "work-items.json"
        target.write_text('{"prior":true}\n', encoding="utf-8")
        with mock.patch.object(tracker.os, "replace", side_effect=OSError("fixture interrupted replacement")):
            with self.assertRaises(OSError): tracker.write_json(target, {"new": True})
        self.assertEqual('{"prior":true}\n', target.read_text(encoding="utf-8"))
        self.assertEqual([], list(self.state.glob(".work-registry-*")))


if __name__ == "__main__":
    unittest.main()
