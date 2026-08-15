from __future__ import annotations

import ast
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
sys.path.insert(0, str(ROOT))

from policy_lib import PolicyError, load_config, validate_bundle, workflow_gaps  # noqa: E402
import acceptance as acceptance_module  # noqa: E402


class AliyunPolicyBundleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.temp = Path(self.temporary.name)
        self.config_path = self.temp / "config.json"
        self.config = json.loads((ROOT / "policy-config.example.json").read_text(encoding="utf-8"))
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.bundle = self.temp / "bundle"

    def render(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(ROOT / "render-policies.py"), "--config", str(self.config_path), "--output", str(self.bundle)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_render_and_strict_validate(self) -> None:
        completed = self.render()
        self.assertEqual(0, completed.returncode, completed.stderr)
        metadata = validate_bundle(self.bundle, ROOT)
        self.assertEqual("NO-GO", metadata["commissioning"]["status"])
        self.assertFalse(metadata["commissioning"]["ramCreateOnlyOrCasEnforced"])

        publisher_trust = json.loads((self.bundle / "publisher-trust.json").read_text(encoding="utf-8"))
        bootstrap_trust = json.loads((self.bundle / "bootstrap-trust.json").read_text(encoding="utf-8"))
        publisher_sub = publisher_trust["Statement"][0]["Condition"]["StringEquals"]["oidc:sub"]
        bootstrap_sub = bootstrap_trust["Statement"][0]["Condition"]["StringEquals"]["oidc:sub"]
        self.assertEqual(["repo:replace-owner/uten_imp:environment:production-release-publisher"], publisher_sub)
        self.assertEqual(["repo:replace-owner/uten_imp:environment:production-release-bootstrap"], bootstrap_sub)
        self.assertNotEqual(publisher_sub, bootstrap_sub)
        for trust in (publisher_trust, bootstrap_trust):
            statement = trust["Statement"][0]
            self.assertEqual("sts:AssumeRole", statement["Action"])
            condition = statement["Condition"]
            self.assertEqual({"StringEquals"}, set(condition))
            self.assertEqual(
                {"oidc:iss", "oidc:aud", "oidc:sub"},
                set(condition["StringEquals"]),
            )
            self.assertEqual(
                ["https://token.actions.githubusercontent.com"],
                condition["StringEquals"]["oidc:iss"],
            )
            self.assertEqual(["github-actions"], condition["StringEquals"]["oidc:aud"])
            self.assertFalse(any("*" in item for item in condition["StringEquals"]["oidc:sub"]))

        downloader = json.loads((self.bundle / "server-downloader-permission.json").read_text(encoding="utf-8"))
        self.assertEqual({"oss:GetObject"}, {action for statement in downloader["Statement"] for action in statement["Action"]})
        resources = {resource for statement in downloader["Statement"] for resource in statement["Resource"]}
        self.assertNotIn("acs:oss:*:*:*", resources)
        self.assertTrue(all("replace-with-private-release-bucket/" in resource for resource in resources))

        publisher = json.loads((self.bundle / "publisher-permission.json").read_text(encoding="utf-8"))
        publisher_actions = {
            action for statement in publisher["Statement"] for action in statement["Action"]
        }
        self.assertEqual(
            {"oss:GetObject", "oss:PutObject", "oss:DeleteObject", "oss:DeleteObjectVersion"},
            publisher_actions,
        )
        publisher_get = next(
            statement for statement in publisher["Statement"]
            if statement["Effect"] == "Allow" and statement["Action"] == ["oss:GetObject"]
        )
        self.assertIn(
            "acs:oss:*:*:replace-with-private-release-bucket/releases/*",
            publisher_get["Resource"],
        )
        bootstrap = json.loads((self.bundle / "bootstrap-permission.json").read_text(encoding="utf-8"))
        bootstrap_actions = {
            action for statement in bootstrap["Statement"] for action in statement["Action"]
        }
        self.assertEqual(publisher_actions, bootstrap_actions)
        for document in (publisher, bootstrap):
            self.assertFalse(
                any(
                    action.startswith("oss:List") or action in {"oss:*", "ram:*", "sts:*"}
                    for statement in document["Statement"]
                    for action in statement["Action"]
                )
            )

    def test_policy_tamper_fails(self) -> None:
        self.assertEqual(0, self.render().returncode)
        path = self.bundle / "server-downloader-permission.json"
        document = json.loads(path.read_text(encoding="utf-8"))
        document["Statement"][0]["Action"].append("oss:PutObject")
        path.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(PolicyError, "strict template"):
            validate_bundle(self.bundle, ROOT)

    def test_wildcard_or_shared_oidc_boundary_fails(self) -> None:
        for mutation in ("issuer", "audience", "environment"):
            candidate = json.loads(json.dumps(self.config))
            if mutation == "issuer":
                candidate["github"]["issuer"] = "https://token.actions.githubusercontent.com/*"
            elif mutation == "audience":
                candidate["github"]["audience"] = "sts.aliyuncs.com"
            else:
                candidate["github"]["bootstrapEnvironment"] = candidate["github"]["publisherEnvironment"]
            path = self.temp / f"bad-{mutation}.json"
            path.write_text(json.dumps(candidate), encoding="utf-8")
            with self.assertRaises(PolicyError):
                load_config(path)

    def test_server_principal_must_be_a_role_not_a_long_lived_ram_user(self) -> None:
        candidate = json.loads(json.dumps(self.config))
        candidate["serverPrincipalArn"] = (
            "acs:ram::1234567890123456:user/uten-imp-server-source"
        )
        path = self.temp / "ram-user.json"
        path.write_text(json.dumps(candidate), encoding="utf-8")
        with self.assertRaisesRegex(PolicyError, "serverPrincipalArn"):
            load_config(path)

    def test_commissionable_mode_fails_closed(self) -> None:
        self.assertEqual(0, self.render().returncode)
        completed = subprocess.run(
            [sys.executable, str(ROOT / "validate-policies.py"), "--bundle", str(self.bundle), "--require-commissionable"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(3, completed.returncode)
        self.assertIn("COMMISSIONING NO-GO", completed.stdout)

    def test_default_acceptance_is_plan_only(self) -> None:
        self.assertEqual(0, self.render().returncode)
        completed = subprocess.run(
            [sys.executable, str(ROOT / "acceptance.py"), "--bundle", str(self.bundle)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("PLAN ONLY", completed.stdout)
        self.assertIn("Write acceptance is disabled", completed.stdout)

    def test_production_bundle_refuses_write_acceptance_before_any_command(self) -> None:
        self.assertEqual(0, self.render().returncode)
        metadata = validate_bundle(self.bundle, ROOT)
        metadata["_bundlePath"] = str(self.bundle)
        with self.assertRaisesRegex(PolicyError, "nonproduction acceptance"):
            acceptance_module.write_acceptance(
                metadata,
                self.temp / "must-not-exist",
                f"WRITE_TEST:{self.config['bucket']}:{self.config['keyPrefix']}",
            )
        self.assertFalse((self.temp / "must-not-exist").exists())

    def test_release_workflow_uses_independent_role_and_environment_boundaries(self) -> None:
        self.assertEqual(0, self.render().returncode)
        metadata = validate_bundle(self.bundle, ROOT)
        gaps = workflow_gaps(metadata, REPO / ".github" / "workflows" / "release.yml")
        self.assertEqual([], gaps)

    def test_workflow_boundary_check_is_job_scoped_not_global_substring_matching(self) -> None:
        self.assertEqual(0, self.render().returncode)
        metadata = validate_bundle(self.bundle, ROOT)
        source = (REPO / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        expected = "role-to-assume: ${{ vars.ALIYUN_RELEASE_PUBLISHER_ROLE_ARN }}"
        broken = source.replace(
            expected,
            "role-to-assume: ${{ vars.ALIYUN_RELEASE_BOOTSTRAP_ROLE_ARN }}",
            1,
        ) + f"\n# decoy outside the publisher job: {expected}\n"
        workflow = self.temp / "broken-release.yml"
        workflow.write_text(broken, encoding="utf-8")
        gaps = workflow_gaps(metadata, workflow)
        self.assertTrue(any(item.startswith("publish-release:") for item in gaps), gaps)

    def test_worm_validation_requires_exact_locked_state_and_positive_retention(self) -> None:
        valid_object = {
            "ObjectWormConfiguration": {
                "ObjectWormEnabled": "Enabled",
                "Rule": [{"Mode": "COMPLIANCE", "RetentionPeriod": {"Days": 30}}],
            }
        }
        acceptance_module._validate_worm_configuration(valid_object, "object")
        acceptance_module._validate_worm_configuration(
            {"WormConfiguration": {"State": "Locked", "RetentionPeriodInDays": "30"}},
            "bucket",
        )
        invalid = (
            ("object", {"ObjectWormEnabled": "Enabled", "Mode": "COMPLIANCE", "Days": 0}),
            ("object", {"ObjectWormEnabled": "Disabled", "Mode": "COMPLIANCE", "Days": 30}),
            ("object", {"ObjectWormEnabled": "Enabled", "Mode": "GOVERNANCE", "Days": 30}),
            ("bucket", {"State": "Unlocked", "RetentionPeriodInDays": 30}),
            ("bucket", {"State": "InProgress", "RetentionPeriodInDays": 30}),
            ("bucket", {"State": "Locked", "RetentionPeriodInDays": 0}),
            ("bucket", {"locked": False, "message": "Locked COMPLIANCE Enabled"}),
        )
        for source, value in invalid:
            with self.subTest(source=source, value=value):
                with self.assertRaisesRegex(PolicyError, "exact locked COMPLIANCE"):
                    acceptance_module._validate_worm_configuration(value, source)

    def test_cloud_command_failure_never_includes_cloud_output(self) -> None:
        completed = subprocess.CompletedProcess(
            ["aliyun", "ram"], 9, stdout="AccessKeyId=LEAK", stderr="SecurityToken=LEAK"
        )
        with mock.patch.object(acceptance_module.subprocess, "run", return_value=completed):
            with self.assertRaises(PolicyError) as raised:
                acceptance_module._run(["aliyun", "ram", "GetRole"])
        self.assertNotIn("LEAK", str(raised.exception))
        self.assertIn("exit 9", str(raised.exception))

    def test_acceptance_workflow_is_manual_read_only_and_cross_role_negative(self) -> None:
        text = (REPO / ".github" / "workflows" / "aliyun-oidc-acceptance.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("expected_release_ref:", text)
        self.assertIn("RELEASE_REF_PROTECTED", text)
        self.assertIn("refs/tags/v", text)
        self.assertIn("READ_ONLY_OIDC_ACCEPTANCE", text)
        self.assertIn("continue-on-error: true", text)
        self.assertIn("test \"$CROSS_ROLE_OUTCOME\" = failure", text)
        self.assertEqual(4, text.count("needs: validate-request"))
        self.assertEqual(2, text.count("ALIBABA_CLOUD_SECURITY_TOKEN"))
        self.assertEqual(4, text.count("/tmp/token"))
        self.assertEqual(4, text.count("audience: github-actions"))
        action_refs = re.findall(r"^\s*uses:\s*[^@\s]+@([^\s]+)", text, re.MULTILINE)
        self.assertEqual(4, len(action_refs))
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref in action_refs))
        self.assertEqual(4, text.count("id-token: write"))
        self.assertEqual(2, text.count("CROSS_ROLE_ARN:"))
        self.assertNotIn("actions/checkout", text)
        self.assertNotIn("put-object", text.lower())
        self.assertNotIn("ALIYUN_RELEASE_ROLE_ARN", text)
        self.assertNotIn("${{ secrets.", text)
        scripts = re.findall(
            r"<<'PY'\n(?P<body>.*?)(?=^          PY$)",
            text,
            re.MULTILINE | re.DOTALL,
        )
        self.assertEqual(1, len(scripts))
        ast.parse(
            "\n".join(line[10:] if line else "" for line in scripts[0].splitlines()) + "\n",
            filename="aliyun-oidc-acceptance-inline.py",
        )
        shell_blocks = re.findall(
            r"(?m)^        run: \|\r?\n(?P<body>(?:(?:          [^\r\n]*)?\r?\n)+)",
            text,
        )
        self.assertGreaterEqual(len(shell_blocks), 5)
        for index, block in enumerate(shell_blocks, start=1):
            script = "\n".join(
                line[10:] if line.startswith("          ") else ""
                for line in block.splitlines()
            ) + "\n"
            script = re.sub(r"\$\{\{.*?\}\}", "GITHUB_EXPRESSION", script)
            checked = subprocess.run(
                ["bash", "-n"], input=script, text=True, capture_output=True, check=False
            )
            self.assertEqual(0, checked.returncode, f"shell block {index}: {checked.stderr}")


if __name__ == "__main__":
    unittest.main()
