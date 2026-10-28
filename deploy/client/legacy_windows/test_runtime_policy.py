"""Regression cases for the shared Python and generated installer policy."""

import re
import unittest

from runtime_policy import render_inno_policy, select_runtime, selection_error


class RuntimeSelectionTests(unittest.TestCase):
    def assert_rejected(self, *arguments, contains=None):
        error = selection_error(*arguments)
        self.assertTrue(error)
        if contains is not None:
            self.assertIn(contains, error)
        with self.assertRaises(ValueError) as raised:
            select_runtime(*arguments)
        self.assertEqual(str(raised.exception), error)

    def test_legacy_os_and_architecture_matrix(self):
        for major, minor, service_pack in ((6, 1, 1), (6, 1, 2), (6, 2, 0), (6, 3, 0)):
            for architecture in ("x86", "x64"):
                with self.subTest(version=(major, minor, service_pack), architecture=architecture):
                    arguments = (major, minor, service_pack, architecture)
                    self.assertEqual(select_runtime(*arguments), "legacy-" + architecture)
                    self.assertEqual(selection_error(*arguments), "")

    def test_win7_sp0_explains_project_baseline(self):
        for architecture in ("x86", "x64"):
            with self.subTest(architecture=architecture):
                self.assert_rejected(6, 1, 0, architecture, contains="SP1")
                error = selection_error(6, 1, 0, architecture)
                self.assertIn("本项目的验证基线", error)
                self.assertIn("不是 Supermium 浏览器官方的硬性要求", error)

    def test_modern_x64_is_always_native_including_future_major(self):
        for major, minor in ((10, 0), (10, 1), (11, 0), (12, 7), (65535, 65535)):
            with self.subTest(version=(major, minor)):
                self.assertEqual(select_runtime(major, minor, 0, "x64"), "native-x64")
                self.assertEqual(selection_error(major, minor, 0, "x64"), "")

    def test_modern_x86_never_falls_back_to_legacy(self):
        for major in (10, 11, 12, 65535):
            with self.subTest(major=major):
                self.assert_rejected(major, 0, 0, "x86", contains="原生客户端")

    def test_arm64_is_rejected_in_both_families(self):
        for major, minor, service_pack in ((6, 1, 1), (6, 2, 0), (6, 3, 0), (10, 0, 0), (11, 0, 0)):
            with self.subTest(version=(major, minor)):
                self.assert_rejected(major, minor, service_pack, "arm64", contains="ARM64")

    def test_unsupported_os_does_not_receive_any_runtime(self):
        versions = ((0, 0), (5, 1), (5, 2), (6, 0), (6, 4), (6, 65535), (7, 0), (8, 0), (9, 0))
        for major, minor in versions:
            for architecture in ("x86", "x64", "arm64"):
                with self.subTest(version=(major, minor), architecture=architecture):
                    self.assert_rejected(major, minor, 3, architecture)

    def test_invalid_version_components_including_bool_are_rejected(self):
        for field in range(3):
            for invalid_value in (-1, 65536, True, False, "1", 1.0, None):
                arguments = [6, 1, 1, "x64"]
                arguments[field] = invalid_value
                with self.subTest(field=field, value=invalid_value):
                    self.assert_rejected(*arguments, contains="版本信息无效")

    def test_architecture_requires_an_explicit_canonical_detection(self):
        for architecture in ("", "amd64", "X64", "ARM64", "ia64", "arm", "unknown", None, 9):
            with self.subTest(architecture=architecture):
                self.assert_rejected(10, 0, 0, architecture, contains="无法识别系统架构")


class GeneratedInnoPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = render_inno_policy()
        cls.error_function, cls.select_function = cls.policy.split("function SelectRuntime", 1)

    def test_fragment_has_exactly_the_two_declared_functions_and_no_section(self):
        self.assertNotIn("[Code]", self.policy)
        self.assertEqual(self.policy.count("function "), 2)
        signature = "(Major, Minor, ServicePackMajor, Architecture: Integer): String;"
        self.assertIn("function RuntimeSelectionError" + signature, self.policy)
        self.assertIn("function SelectRuntime" + signature, self.policy)
        self.assertEqual(self.policy, render_inno_policy())

    def test_selection_checks_rejection_before_any_runtime_assignment(self):
        validation = "if RuntimeSelectionError(Major, Minor, ServicePackMajor, Architecture) <> '' then"
        self.assertLess(self.select_function.index(validation), self.select_function.index("'legacy-x86'"))
        self.assertIn("Result := '';", self.select_function)

    def test_legacy_conditions_are_exact_and_only_modern_condition_selects_native(self):
        blocks = re.findall(
            r"  if ([^\n]+) then\n  begin\n(.*?)  end;",
            self.select_function,
            re.DOTALL,
        )
        self.assertEqual(len(blocks), 4)
        expected_conditions = [
            "(Major = 6) and (Minor = 1)",
            "(Major = 6) and (Minor = 2)",
            "(Major = 6) and (Minor = 3)",
            "(Major >= 10)",
        ]
        self.assertEqual([condition for condition, _ in blocks], expected_conditions)
        for _, body in blocks[:3]:
            self.assertIn("Architecture = 0", body)
            self.assertIn("Architecture = 9", body)
            self.assertIn("'legacy-x86'", body)
            self.assertIn("'legacy-x64'", body)
            self.assertNotIn("native", body)
        self.assertIn("Architecture = 9", blocks[3][1])
        self.assertIn("'native-x64'", blocks[3][1])
        self.assertNotIn("legacy", blocks[3][1])
        self.assertNotIn("Architecture = 0", blocks[3][1])
        self.assertNotIn("Architecture = 12", self.select_function)

    def test_service_pack_input_bounds_and_architecture_rejections_are_present(self):
        self.assertIn("if ServicePackMajor < 1 then", self.error_function)
        self.assertIn(selection_error(6, 1, 0, "x64"), self.error_function)
        self.assertIn("(Architecture <> 0) and (Architecture <> 9) and (Architecture <> 12)", self.error_function)
        for field in ("Major", "Minor", "ServicePackMajor"):
            self.assertIn(f"({field} < 0) or ({field} > 65535)", self.error_function)
        for arguments in ((10, 0, 0, "x86"), (6, 2, 0, "arm64"), (6, 4, 0, "x64")):
            self.assertIn(selection_error(*arguments), self.error_function)


if __name__ == "__main__":
    unittest.main()
