import unittest

from audit_legacy_goods_semantics import location,mould_codes,rear_codes


class GoodsSemanticRulesTest(unittest.TestCase):
    def test_explicit_rear_insert_is_extracted(self):
        self.assertEqual({"45A"},rear_codes("换后模45A镶件"))
        self.assertEqual({"V7-012"},rear_codes("换前模芯V7-012  后模镶件用V7-012"))

    def test_front_core_and_unlabelled_insert_are_never_rear(self):
        for note in ["换前模镶件","换6M镶件","前模芯MA-62-B 模具MA-62","后模借用MA-62","换后模"]:
            with self.subTest(note=note):
                self.assertEqual(set(),rear_codes(note))

    def test_multiple_distinct_rear_inserts_remain_ambiguous(self):
        self.assertEqual({"45A","平"},rear_codes("换后模45A镶件；换后模平镶件"))

    def test_labelled_mould_code_does_not_pick_front_core_or_fee(self):
        self.assertEqual({"A8-01"},mould_codes("模具A8-01 模芯A8-01-C"))
        self.assertEqual(set(),mould_codes("退模具费8000元"))
        self.assertEqual(set(),mould_codes("金本模具"))

    def test_code_before_mould_label_is_evidence_without_fuzzy_padding(self):
        self.assertEqual({"Q5-06"},mould_codes("Q5-06模具 换前模芯 编号Q5-019A"))

    def test_explicit_mould_code_rack_enriches_place(self):
        self.assertEqual(("A2-14","注塑车间 / A2-14"),location("A8-01【A2-14】","注塑车间"))
        self.assertEqual(("A2-14","A2-14"),location("A8-01【A2-14】",""))

    def test_non_location_suffix_is_not_a_rack(self):
        self.assertIsNone(location("A8-01【封存】","注塑车间"))
        self.assertIsNone(location("A8-01【A2-14】其他说明","注塑车间"))

    def test_existing_rack_is_idempotent_without_substring_confusion(self):
        self.assertEqual(("A2-14","注塑车间 / A2-14"),location("A8-01【A2-14】","注塑车间 / A2-14"))
        self.assertEqual(("A2-1","A2-14 / A2-1"),location("A8-01【A2-1】","A2-14"))


if __name__ == "__main__":
    unittest.main()
