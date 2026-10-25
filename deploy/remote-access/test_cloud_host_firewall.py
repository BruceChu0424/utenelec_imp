"""Cloud host policy and guarded-change regressions; no real host networking."""
import copy
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("cloud_host_firewall", ROOT / "cloud_host_firewall.py")
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


def policy():
    return {"schema_version": 1, "role": "cloud", "public_interface": "eth0", "dhcpv4": True,
            "ssh_source_policy": "host-allowlist",
            "admin_ipv4_cidrs": ["8.8.8.8/32"], "wireguard_ipv4_cidrs": ["0.0.0.0/0"]}


OLD_SSH = "8.8.8.8 40000 10.0.0.5 22"
NEW_SSH = "8.8.8.8 40001 10.0.0.5 22"


class PolicyTests(unittest.TestCase):
    def test_render_is_a_separate_default_deny_cloud_table(self):
        rendered = host.render_policy(policy())
        self.assertIn("table inet uten_cloud_host {", rendered)
        self.assertEqual(2, rendered.count("policy drop;"))
        self.assertIn("priority 10", rendered)
        self.assertIn("ct state established,related accept", rendered)
        self.assertIn("8.8.8.8/32", rendered)
        self.assertIn("udp dport 51820", rendered)
        self.assertIn("tcp dport 443", rendered)
        self.assertIn("udp sport 67 udp dport 68", rendered)
        self.assertIn("ip6 hoplimit 255", rendered)
        self.assertNotIn("@@", rendered)
        self.assertNotIn("hook output", rendered)
        self.assertNotIn("delete table", rendered)

    def test_ssh_never_inherits_broad_or_placeholder_sources(self):
        for source in ("0.0.0.0/0", "8.8.8.8", "8.8.8.0/24", "127.0.0.1/32", "10.0.0.1/32",
                       "100.64.0.1/32", "203.0.113.5/32", "::/0", "REPLACE/32", "8.8.8.8/32\naccept"):
            candidate = policy()
            candidate["admin_ipv4_cidrs"] = [source]
            with self.subTest(source=source), self.assertRaises(host.UnsafeChange):
                host.render_policy(candidate)

    def test_dynamic_ip_transition_uses_explicit_single_address_sources(self):
        candidate = policy()
        candidate["admin_ipv4_cidrs"] = ["9.9.9.9/32", "8.8.8.8/32"]
        rendered = host.render_policy(candidate)
        self.assertIn("8.8.8.8/32, 9.9.9.9/32", rendered)
        host.approve_session(candidate, host.ssh_session(OLD_SSH))
        with self.assertRaisesRegex(host.UnsafeChange, "omits"):
            host.approve_session(policy(), host.ssh_session("9.9.9.9 44000 10.0.0.5 22"))

    def test_security_group_mode_deliberately_delegates_ssh_sources_without_a_stale_host_cidr(self):
        candidate = {**policy(), "ssh_source_policy": "security-group", "admin_ipv4_cidrs": []}
        rendered = host.render_policy(candidate)
        self.assertIn('iifname "eth0" meta nfproto ipv4 tcp dport 22 ct state new accept', rendered)
        self.assertNotIn("8.8.8.8", rendered)
        host.approve_session(candidate, host.ssh_session("9.9.9.9 44000 10.0.0.5 22"))
        with self.assertRaises(host.UnsafeChange):
            host.render_policy({**candidate, "admin_ipv4_cidrs": ["8.8.8.8/32"]})

    def test_role_unknown_fields_interface_and_dhcp_are_fail_closed(self):
        for change in ({"role": "company"}, {"role": "cloud\naccept"}, {"extra": True},
                       {"public_interface": "eth0\" accept"}, {"public_interface": "REPLACE_IFACE"},
                       {"dhcpv4": "false"}, {"admin_ipv4_cidrs": []}, {"schema_version": True},
                       {"admin_ipv4_cidrs": ["8.8.8.8/32", "8.8.8.8/32"]}):
            with self.subTest(change=change), self.assertRaises(host.UnsafeChange):
                host.render_policy({**policy(), **change})

    def test_udp_can_be_public_for_dynamic_company_addresses_but_not_mixed_with_fake_allowlists(self):
        candidate = policy()
        candidate["wireguard_ipv4_cidrs"] = ["9.9.9.9/32"]
        self.assertIn("ip saddr { 9.9.9.9/32 } udp dport 51820", host.render_policy(candidate))
        candidate["wireguard_ipv4_cidrs"] += ["0.0.0.0/0"]
        with self.assertRaises(host.UnsafeChange):
            host.render_policy(candidate)

    def test_dhcp_false_does_not_open_a_service_by_implicit_default(self):
        candidate = {**policy(), "dhcpv4": False}
        self.assertNotIn("udp sport 67", host.render_policy(candidate))

    def test_transactions_cannot_replace_tunnel_or_operator_tables(self):
        rendered = host.render_policy(policy())
        combined = host.transaction(rendered, True)
        self.assertTrue(combined.startswith("delete table inet uten_cloud_host\n"))
        self.assertEqual("delete table inet uten_cloud_host\n", host.transaction(None, True))
        self.assertEqual("", host.transaction(None, False))
        for invalid in ("flush ruleset\n" + rendered, rendered + "\ntable inet other {}\n",
                        rendered.rstrip() + " table inet other {}", rendered.rstrip() + " delete table inet other",
                        rendered.replace("uten_cloud_host", "uten_remote"), "include \"unsafe\"\n" + rendered):
            with self.subTest(invalid=invalid[:40]), self.assertRaises(host.UnsafeChange):
                host.transaction(invalid, True)

    def test_owned_table_validation_understands_comments_and_escaped_strings(self):
        rendered = host.render_policy(policy())
        host.validate_table(rendered.replace('comment "Uten cloud host firewall schema 1"',
                                            'comment "quote \\\" } table include" # an ignored }\n'))
        with self.assertRaises(host.UnsafeChange):
            host.validate_table(rendered.replace('comment "Uten cloud host firewall schema 1"', 'comment "unterminated'))

    def test_duplicate_json_and_ambiguous_ssh_sessions_are_rejected(self):
        with self.assertRaises(host.UnsafeChange):
            host.decode('{"role":"cloud","role":"company"}')
        for session in (None, "", "127.0.0.1 40000 10.0.0.5 22", "8.8.8.8 0 10.0.0.5 22",
                        "8.8.8.8 40000 10.0.0.5 2222", "8.8.8.8 40000 10.0.0.5 22 extra"):
            with self.subTest(session=session), self.assertRaises(host.UnsafeChange):
                host.ssh_session(session)

    def test_offline_render_does_not_install_or_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, target = root / "policy.json", root / "candidate.nft"
            source.write_text(json.dumps(policy()))
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(0, host.main(["render", "--policy", str(source), "--output", str(target)]))
                before = target.read_bytes()
                self.assertEqual(1, host.main(["render", "--policy", str(source), "--output", str(target)]))
            self.assertEqual(before, target.read_bytes())

    def test_boot_unit_is_cloud_only_and_has_no_global_firewall_stop_action(self):
        unit = (ROOT / "units/uten-cloud-host-firewall.service").read_text()
        self.assertIn("Before=network-pre.target", unit)
        self.assertIn("ConditionPathExists=/var/lib/uten-remote/cloud-host-firewall/active.json", unit)
        self.assertIn("CapabilityBoundingSet=CAP_NET_ADMIN", unit)
        self.assertNotIn("ExecStop=", unit)
        self.assertNotIn("flush", unit)


class FakeHost:
    def __init__(self):
        self.calls = []
        self.tables = {"uten_remote": "table inet uten_remote {\n set sentinel { type inet_service; elements = { 8443 }; }\n}\n",
                       "operator_existing": "table inet operator_existing {}\n"}
        self.sessions = [OLD_SSH.split()]
        self.incomplete_sessions = []
        self.enabled = False
        self.timer_active = False
        self.fail_timer = False
        self.fail_check = False
        self.fail_enable = False

    def __call__(self, command, *, input=None, **kwargs):
        self.calls.append((command, input))
        status, output = 0, ""
        if command[0] == host.NFT:
            if command[1:] == ["-j", "list", "tables"]:
                output = json.dumps({"nftables": [{"table": {"family": "inet", "name": name}} for name in self.tables]})
            elif command[1:4] == ["list", "table", "inet"]:
                output = self.tables[command[4]]
            elif command[1:] == ["--check", "-f", "-"]:
                status = int(self.fail_check)
            elif command[1:] == ["-f", "-"]:
                if input.startswith("delete table inet uten_cloud_host\n"):
                    self.tables.pop(host.TABLE, None)
                    input = input.split("\n", 1)[1]
                if input:
                    self.tables[host.TABLE] = input
            else:
                raise AssertionError(command)
        elif command[0] == host.SS:
            if "all" in command:
                rows = [("ESTAB", s) for s in self.sessions] + self.incomplete_sessions
                output = "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n" + "\n".join(
                    f"{state} 0 0 {s[2]}:{s[3]} {s[0]}:{s[1]}" for state, s in rows)
            else:
                output = "\n".join(f"0 0 {s[2]}:{s[3]} {s[0]}:{s[1]}" for s in self.sessions)
        elif command[0] == host.SYSTEMD_RUN:
            status = int(self.fail_timer)
            self.timer_active = not self.fail_timer
        elif command[:2] == [host.SYSTEMCTL, "is-enabled"]:
            status, output = (0, "enabled") if self.enabled else (1, "disabled")
        elif command[:2] == [host.SYSTEMCTL, "is-active"]:
            status, output = (0, "active") if self.timer_active else (4, "unknown")
        elif command[:2] == [host.SYSTEMCTL, "enable"]:
            if self.fail_enable:
                status = 1
            else:
                self.enabled = True
        elif command[:2] == [host.SYSTEMCTL, "disable"]:
            self.enabled = False
        elif command[:2] == [host.SYSTEMCTL, "stop"]:
            self.timer_active = False
        else:
            raise AssertionError(command)
        return subprocess.CompletedProcess(command, status, output, "")


@unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "root-only private receipt and control-flow contract")
class GuardedChangeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-cloud-host-controller-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        helper, template = self.root / "helper.py", self.root / "table.nft.tmpl"
        shutil.copyfile(ROOT / "cloud_host_firewall.py", helper)
        shutil.copyfile(ROOT / "templates/cloud-host-firewall.nft.tmpl", template)
        helper.chmod(0o600); template.chmod(0o600)
        for name, path in (("HELPER", str(helper)), ("TEMPLATE", template)):
            patched = patch.object(host, name, path)
            patched.start()
            self.addCleanup(patched.stop)
        self.kernel = FakeHost()
        self.controller = host.Controller(self.root / "state", self.kernel)

    def trial(self):
        return self.controller.trial(policy(), OLD_SSH, recovery_verified=True)

    def test_recovery_and_actual_ssh_source_are_mandatory_before_any_trial(self):
        for connection, verified in ((OLD_SSH, False), ("9.9.9.9 40000 10.0.0.5 22", True), (None, True)):
            with self.subTest(connection=connection), self.assertRaises(host.UnsafeChange):
                self.controller.trial(policy(), connection, recovery_verified=verified)
        self.kernel.sessions = []
        with self.assertRaises(host.UnsafeChange):
            self.trial()
        self.assertNotIn(host.TABLE, self.kernel.tables)
        self.assertFalse(self.kernel.timer_active)

    def test_security_group_mode_requires_console_control_but_does_not_require_an_os_password(self):
        candidate = {**policy(), "ssh_source_policy": "security-group", "admin_ipv4_cidrs": []}
        with self.assertRaisesRegex(host.UnsafeChange, "cloud-console"):
            self.controller.trial(candidate, OLD_SSH)
        trial = self.controller.trial(candidate, OLD_SSH, security_group_console_verified=True)
        self.kernel.sessions.append(NEW_SSH.split())
        self.assertEqual("CONFIRMED", self.controller.confirm(trial["token"], NEW_SSH)["state"])

    def test_timer_must_be_armed_before_validation_and_atomic_application(self):
        result = self.trial()
        self.assertEqual("TRIAL", result["state"])
        commands = [item[0] for item in self.kernel.calls]
        arm = next(i for i, c in enumerate(commands) if c[0] == host.SYSTEMD_RUN)
        check = commands.index([host.NFT, "--check", "-f", "-"])
        apply = commands.index([host.NFT, "-f", "-"])
        self.assertLess(arm, check)
        self.assertLess(check, apply)
        self.assertIn("--on-active=180s", commands[arm])
        self.assertFalse(self.controller.active.exists())
        self.assertFalse(self.kernel.enabled)
        self.assertIn("uten_remote", self.kernel.tables)
        self.assertIn("operator_existing", self.kernel.tables)

    def test_failed_timer_or_nft_check_never_applies_a_candidate(self):
        self.kernel.fail_timer = True
        with self.assertRaises(host.UnsafeChange):
            self.trial()
        self.assertNotIn(host.TABLE, self.kernel.tables)
        self.assertFalse(any(c == [host.NFT, "-f", "-"] for c, _ in self.kernel.calls))
        token = json.loads(self.controller.pending.read_text())["token"]
        self.controller.rollback(token)
        self.kernel.fail_timer = False
        self.kernel.fail_check = True
        with self.assertRaises(host.UnsafeChange):
            self.trial()
        self.assertNotIn(host.TABLE, self.kernel.tables)
        self.assertTrue(self.kernel.timer_active)

    def test_existing_and_multiplexed_ssh_cannot_confirm(self):
        self.kernel.sessions.append(NEW_SSH.split())
        trial = self.trial()
        for connection in (OLD_SSH, NEW_SSH):
            with self.subTest(connection=connection), self.assertRaises(host.UnsafeChange):
                self.controller.confirm(trial["token"], connection)
        self.assertTrue(self.kernel.timer_active)
        self.assertFalse(self.controller.active.exists())

    def assert_connection_before_cutoff_is_rejected(self, stage):
        original = self.kernel.__call__
        injected = []

        def inject(command, **kwargs):
            matches = ((stage == "timer" and command[0] == host.SYSTEMD_RUN)
                       or (stage == "check" and command == [host.NFT, "--check", "-f", "-"])
                       or (stage == "apply" and command == [host.NFT, "-f", "-"])
                       or (stage == "readback" and command == [host.NFT, "list", "table", "inet", host.TABLE]))
            if matches and not injected:
                injected.append(host.TABLE in self.kernel.tables)
                self.kernel.sessions.append(NEW_SSH.split())
            return original(command, **kwargs)

        self.controller.runner = inject
        trial = self.trial()
        self.assertEqual([stage == "readback"], injected)
        with self.assertRaisesRegex(host.UnsafeChange, "new SSH"):
            self.controller.confirm(trial["token"], NEW_SSH)
        self.assertTrue(self.kernel.timer_active)
        self.assertFalse(self.controller.active.exists())
        later = "8.8.8.8 40002 10.0.0.5 22"
        self.kernel.sessions.append(later.split())
        self.assertEqual("CONFIRMED", self.controller.confirm(trial["token"], later)["state"])

    def test_connection_created_while_timer_arms_is_not_new_policy_proof(self):
        self.assert_connection_before_cutoff_is_rejected("timer")

    def test_connection_created_during_nft_check_is_not_new_policy_proof(self):
        self.assert_connection_before_cutoff_is_rejected("check")

    def test_connection_created_just_before_atomic_apply_is_not_new_policy_proof(self):
        self.assert_connection_before_cutoff_is_rejected("apply")

    def test_connection_present_at_post_apply_readback_is_conservatively_excluded(self):
        self.assert_connection_before_cutoff_is_rejected("readback")

    def test_preexisting_half_open_tcp_cannot_finish_later_and_count_as_new(self):
        original = self.kernel.__call__

        def inject(command, **kwargs):
            if command[0] == host.SYSTEMD_RUN:
                self.kernel.incomplete_sessions.append(("SYN-RECV", NEW_SSH.split()))
            return original(command, **kwargs)

        self.controller.runner = inject
        trial = self.trial()
        self.kernel.incomplete_sessions.clear()
        self.kernel.sessions.append(NEW_SSH.split())
        with self.assertRaisesRegex(host.UnsafeChange, "new SSH"):
            self.controller.confirm(trial["token"], NEW_SSH)
        self.assertTrue(self.kernel.timer_active)

    def test_failed_post_apply_tcp_capture_cannot_be_confirmed_or_persisted(self):
        original = self.kernel.__call__
        blocked = [True]

        def fail_capture(command, **kwargs):
            if command[0] == host.SS and host.TABLE in self.kernel.tables and blocked[0]:
                return subprocess.CompletedProcess(command, 1, "", "test readback failure")
            return original(command, **kwargs)

        self.controller.runner = fail_capture
        with self.assertRaises(host.UnsafeChange):
            self.trial()
        pending = json.loads(self.controller.pending.read_text())
        self.assertFalse(pending["confirmation_ready"])
        blocked[0] = False
        self.kernel.sessions.append(NEW_SSH.split())
        with self.assertRaisesRegex(host.UnsafeChange, "did not complete"):
            self.controller.confirm(pending["token"], NEW_SSH)
        self.assertFalse(self.controller.active.exists())
        self.assertFalse(self.kernel.enabled)
        self.assertTrue(self.kernel.timer_active)
        self.controller.rollback(pending["token"])
        self.assertNotIn(host.TABLE, self.kernel.tables)

    def test_failed_post_apply_receipt_write_retains_an_unconfirmable_trial(self):
        original = host.atomic_json

        def fail_ready(path, value):
            if path == self.controller.pending and value.get("confirmation_ready") is True:
                raise OSError("test ready receipt write failure")
            return original(path, value)

        with patch.object(host, "atomic_json", side_effect=fail_ready):
            with self.assertRaisesRegex(OSError, "receipt write"):
                self.trial()
        pending = json.loads(self.controller.pending.read_text())
        self.assertFalse(pending["confirmation_ready"])
        self.kernel.sessions.append(NEW_SSH.split())
        with self.assertRaisesRegex(host.UnsafeChange, "did not complete"):
            self.controller.confirm(pending["token"], NEW_SSH)
        self.assertFalse(self.controller.active.exists())
        self.assertTrue(self.kernel.timer_active)

    def test_new_ssh_confirms_then_and_only_then_persists_boot_policy(self):
        trial = self.trial()
        self.kernel.sessions.append(NEW_SSH.split())
        result = self.controller.confirm(trial["token"], NEW_SSH)
        self.assertEqual("CONFIRMED", result["state"])
        self.assertTrue(self.kernel.enabled)
        self.assertFalse(self.kernel.timer_active)
        self.assertFalse(self.controller.pending.exists())
        active = json.loads(self.controller.active.read_text())
        self.assertEqual(host.validate_policy(policy()), active["policy"])
        self.assertEqual(host.ACTIVE_FORMAT, active["format"])
        self.assertEqual("CONFIRMED_POLICY_LOADED", self.controller.boot()["state"])

    def confirm_first_policy(self):
        trial = self.trial()
        self.kernel.sessions.append(NEW_SSH.split())
        self.controller.confirm(trial["token"], NEW_SSH)

    def test_confirmed_template_drift_cannot_generate_unreviewed_boot_rules(self):
        self.confirm_first_policy()
        before_table, before_active = self.kernel.tables[host.TABLE], self.controller.active.read_bytes()
        host.TEMPLATE.write_text(host.TEMPLATE.read_text().replace("@@SSH_RULE@@", "# @@SSH_RULE@@"))
        with self.assertRaisesRegex(host.UnsafeChange, "identity|template|receipt"):
            self.controller.boot()
        self.assertEqual(before_table, self.kernel.tables[host.TABLE])
        self.assertEqual(before_active, self.controller.active.read_bytes())

    def test_confirmed_helper_drift_cannot_load_a_previous_policy_as_newly_reviewed(self):
        self.confirm_first_policy()
        before_table, before_active = self.kernel.tables[host.TABLE], self.controller.active.read_bytes()
        Path(host.HELPER).write_bytes(Path(host.HELPER).read_bytes() + b"\n# unreviewed helper upgrade\n")
        with self.assertRaisesRegex(host.UnsafeChange, "identity|helper|receipt"):
            self.controller.boot()
        self.assertEqual(before_table, self.kernel.tables[host.TABLE])
        self.assertEqual(before_active, self.controller.active.read_bytes())

    def test_bound_active_receipt_rejects_digest_or_policy_byte_inconsistency(self):
        import hashlib
        self.confirm_first_policy()
        original = json.loads(self.controller.active.read_text())
        before_table = self.kernel.tables[host.TABLE]
        variants = []
        changed = copy.deepcopy(original)
        changed["rendered"] = changed["rendered"].replace("tcp dport 22", "tcp dport 2222")
        variants.append(changed)
        changed = copy.deepcopy(changed)
        changed["rendered_sha256"] = hashlib.sha256(changed["rendered"].encode()).hexdigest()
        variants.append(changed)
        changed = copy.deepcopy(original)
        changed["policy"]["dhcpv4"] = not changed["policy"]["dhcpv4"]
        variants.append(changed)
        for changed in variants:
            with self.subTest(fields=list(changed)):
                host.atomic_json(self.controller.active, changed)
                active_bytes = self.controller.active.read_bytes()
                with self.assertRaises(host.UnsafeChange):
                    self.controller.boot()
                self.assertEqual(before_table, self.kernel.tables[host.TABLE])
                self.assertEqual(active_bytes, self.controller.active.read_bytes())

    def test_template_upgrade_requires_a_new_trial_before_it_can_be_loaded_at_boot(self):
        self.confirm_first_policy()
        host.TEMPLATE.write_bytes(host.TEMPLATE.read_bytes() + b"\n# reviewed template upgrade candidate\n")
        with self.assertRaises(host.UnsafeChange):
            self.controller.boot()
        trial = self.trial()
        later = "8.8.8.8 40003 10.0.0.5 22"
        self.kernel.sessions.append(later.split())
        self.controller.confirm(trial["token"], later)
        self.assertEqual("CONFIRMED_POLICY_LOADED", self.controller.boot()["state"])

    def test_reviewed_helper_upgrade_requires_a_new_trial_using_the_new_implementation(self):
        self.confirm_first_policy()
        upgraded_path = Path(host.HELPER)
        upgraded_path.write_bytes(upgraded_path.read_bytes() + b"\n# reviewed helper upgrade fixture\n")
        upgraded_spec = importlib.util.spec_from_file_location("upgraded_cloud_host_fixture", upgraded_path)
        upgraded = importlib.util.module_from_spec(upgraded_spec)
        upgraded_spec.loader.exec_module(upgraded)
        upgraded.HELPER, upgraded.TEMPLATE = str(upgraded_path), host.TEMPLATE
        controller = upgraded.Controller(self.controller.state, self.kernel)
        with self.assertRaisesRegex(upgraded.UnsafeChange, "identity"):
            controller.boot()
        trial = controller.trial(policy(), OLD_SSH, recovery_verified=True)
        later = "8.8.8.8 40004 10.0.0.5 22"
        self.kernel.sessions.append(later.split())
        controller.confirm(trial["token"], later)
        self.assertEqual("CONFIRMED_POLICY_LOADED", controller.boot()["state"])

    def test_legacy_unbound_active_policy_is_evidence_until_a_new_trial_confirms_it(self):
        self.controller.state.mkdir(mode=0o700)
        host.atomic_json(self.controller.active, policy())
        self.kernel.tables[host.TABLE] = host.render_policy(policy())
        original_table, original_active = self.kernel.tables[host.TABLE], self.controller.active.read_bytes()
        with self.assertRaisesRegex(host.UnsafeChange, "unbound"):
            self.controller.boot()
        self.assertEqual(original_table, self.kernel.tables[host.TABLE])
        self.assertEqual(original_active, self.controller.active.read_bytes())
        trial = self.trial()
        self.kernel.sessions.append(NEW_SSH.split())
        self.controller.confirm(trial["token"], NEW_SSH)
        self.assertEqual(host.ACTIVE_FORMAT, json.loads(self.controller.active.read_text())["format"])
        self.assertEqual("CONFIRMED_POLICY_LOADED", self.controller.boot()["state"])

    def test_timeout_missing_table_or_drift_cannot_be_confirmed(self):
        trial = self.trial()
        self.kernel.sessions.append(NEW_SSH.split())
        original = self.kernel.tables[host.TABLE]
        self.kernel.tables[host.TABLE] = original + "# out of band change\n"
        with self.assertRaisesRegex(host.UnsafeChange, "changed"):
            self.controller.confirm(trial["token"], NEW_SSH)
        self.kernel.tables[host.TABLE] = original
        with patch.object(host.time, "monotonic", return_value=time.monotonic() + 1000):
            with self.assertRaisesRegex(host.UnsafeChange, "expired"):
                self.controller.confirm(trial["token"], NEW_SSH)
        self.assertTrue(self.kernel.timer_active)
        self.assertFalse(self.controller.active.exists())

    def test_changing_the_recovery_helper_or_boot_template_invalidates_confirmation(self):
        trial = self.trial()
        self.kernel.sessions.append(NEW_SSH.split())
        for path in (Path(host.HELPER), host.TEMPLATE):
            original = path.read_bytes()
            path.write_bytes(original + b"\n# unreviewed upgrade during trial\n")
            with self.subTest(path=path.name), self.assertRaisesRegex(host.UnsafeChange, "changed during trial"):
                self.controller.confirm(trial["token"], NEW_SSH)
            path.write_bytes(original)
        self.assertTrue(self.kernel.timer_active)
        self.assertFalse(self.controller.active.exists())

    def test_rollback_restores_only_the_owned_table_and_previous_boot_state(self):
        previous = {**policy(), "dhcpv4": False}
        self.controller.state.mkdir(mode=0o700)
        host.atomic_json(self.controller.active, previous)
        self.kernel.tables[host.TABLE] = host.render_policy(previous)
        self.kernel.enabled = True
        before = copy.deepcopy(self.kernel.tables)
        trial = self.trial()
        self.assertEqual("ROLLED_BACK", self.controller.rollback(trial["token"])["state"])
        self.assertEqual(before, self.kernel.tables)
        self.assertEqual(previous, json.loads(self.controller.active.read_text()))
        self.assertTrue(self.kernel.enabled)
        self.assertFalse(self.kernel.timer_active)

    def test_failure_during_persistence_keeps_rollback_authority(self):
        trial = self.trial()
        self.kernel.sessions.append(NEW_SSH.split())
        self.kernel.fail_enable = True
        with self.assertRaises(host.UnsafeChange):
            self.controller.confirm(trial["token"], NEW_SSH)
        self.assertTrue(self.kernel.timer_active)
        self.kernel.fail_enable = False
        self.controller.rollback(trial["token"])
        self.assertFalse(self.controller.active.exists())
        self.assertNotIn(host.TABLE, self.kernel.tables)
        self.assertFalse(self.kernel.enabled)

    def test_first_trial_reboot_has_no_enabled_boot_entry_and_needs_explicit_rollback(self):
        trial = self.trial()
        self.assertFalse(self.kernel.enabled)
        self.assertFalse(self.controller.active.exists())
        unit = (ROOT / "units/uten-cloud-host-firewall.service").read_text()
        self.assertIn("ConditionPathExists=/var/lib/uten-remote/cloud-host-firewall/active.json", unit)
        pending = json.loads(self.controller.pending.read_text())
        pending["boot_id"] = "a-previous-boot"
        host.atomic_json(self.controller.pending, pending)
        self.kernel.timer_active = False
        self.kernel.tables.pop(host.TABLE)
        # The actual enabled+ConditionPathExists gate is false. Do not call
        # boot() and pretend systemd would dispatch this first unconfirmed run.
        self.assertFalse(self.kernel.enabled and self.controller.active.exists())
        self.assertTrue(self.controller.pending.exists())
        with self.assertRaisesRegex(host.UnsafeChange, "earlier boot"):
            self.trial()
        self.assertEqual("ROLLED_BACK", self.controller.rollback(trial["token"])["state"])
        self.assertFalse(self.controller.pending.exists())
        self.assertNotIn(host.TABLE, self.kernel.tables)

    def test_enabled_confirmed_boot_entry_recovers_a_later_unconfirmed_trial(self):
        self.confirm_first_policy()
        confirmed_active = self.controller.active.read_bytes()
        trial = self.controller.trial({**policy(), "dhcpv4": False}, OLD_SSH, recovery_verified=True)
        self.kernel.timer_active = False
        self.kernel.tables.pop(host.TABLE)
        self.assertTrue(self.kernel.enabled and self.controller.active.exists())
        self.assertEqual("ROLLED_BACK", self.controller.boot()["state"])
        self.assertIn(host.TABLE, self.kernel.tables)
        self.assertEqual(json.loads(confirmed_active), json.loads(self.controller.active.read_text()))
        self.assertFalse(self.controller.pending.exists())
        self.assertEqual("NO_PENDING_TRIAL", self.controller.rollback(trial["token"])["state"])

    def test_parallel_trial_or_wrong_token_cannot_replace_pending_authority(self):
        trial = self.trial()
        before = self.controller.pending.read_bytes()
        with self.assertRaises(host.UnsafeChange):
            self.trial()
        with self.assertRaises(host.UnsafeChange):
            self.controller.rollback("0" * 32)
        self.assertEqual(before, self.controller.pending.read_bytes())
        self.controller.rollback(trial["token"])


if __name__ == "__main__":
    unittest.main()
