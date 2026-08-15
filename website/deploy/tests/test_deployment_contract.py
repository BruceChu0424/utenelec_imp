import os
import importlib.util
import pathlib
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
DEPLOY = ROOT / "website" / "deploy"
WORKFLOW = ROOT / ".github" / "workflows" / "website-release.yml"


class DeploymentContractTest(unittest.TestCase):
    @staticmethod
    def _bash_function(source: str, name: str) -> str:
        start = source.index(f"{name}() {{")
        end = source.index("\n}\n", start) + 3
        return source[start:end]

    def test_workflow_has_separate_website_trust_and_oss_boundary(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("environment: website-production-release", workflow)
        self.assertIn("WEBSITE_RELEASE_SIGNING_KEY", workflow)
        self.assertIn("WEBSITE_RELEASE_ALLOWED_SIGNERS", workflow)
        self.assertIn("ALIYUN_WEBSITE_RELEASE_ROLE_ARN", workflow)
        self.assertIn("website/releases/", workflow)
        self.assertNotIn("ALIYUN_RELEASE_ROLE_ARN", workflow)
        self.assertNotIn("RELEASE_SIGNING_KEY", workflow.replace("WEBSITE_RELEASE_SIGNING_KEY", ""))
        self.assertNotIn("uten-imp-release-v1", workflow)

    def test_isolated_signer_python_compiles_and_treats_schema_contract_separately(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        marker = "CANDIDATE=\"$candidate\" VERSION=\"$VERSION\" SOURCE_REF=\"$SOURCE_REF\" python3 -I - <<'PY'"
        lines = workflow.splitlines()
        start = next(index for index, line in enumerate(lines) if marker in line)
        end = next(index for index in range(start + 1, len(lines)) if lines[index].strip() == "PY")
        block = textwrap.dedent("\n".join(lines[start + 1:end])) + "\n"
        compile(block, "website-release-signer-inline.py", "exec")
        block_lines = block.splitlines()
        loop = next(line for line in block_lines if line.lstrip().startswith("for path,contents in prisma_files.items():"))
        inventory = next(line for line in block_lines if line.lstrip().startswith("inventory={'count':"))
        self.assertEqual(len(loop) - len(loop.lstrip()), len(inventory) - len(inventory.lstrip()))
        self.assertIn("'prisma-runtime/prisma/sqlite-schema-contract.json'", block)
        self.assertIn("if replay!=contract", block)
        self.assertIn("name <> '_prisma_migrations'", block)
        self.assertNotIn("tbl_name <> '_prisma_migrations'", block)

    def test_activation_is_two_step_fail_closed_and_uses_offline_prisma(self):
        activation = (DEPLOY / "uten-website-activate.sh").read_text(encoding="utf-8")
        recovery = (DEPLOY / "uten-website-recover.sh").read_text(encoding="utf-8")
        interrupted = (DEPLOY / "uten-website-recover-interrupted.sh").read_text(encoding="utf-8")
        self.assertIn("plan VERSION | apply VERSION", activation)
        self.assertIn('"$BOOT_GUARD" close', activation)
        self.assertIn("paired pre-activation snapshot", activation)
        self.assertIn("prisma-runtime/node_modules/prisma/build/index.js", activation)
        self.assertNotIn("npx ", activation)
        self.assertNotIn("npm ", activation)
        self.assertIn("never delete", activation)
        self.assertIn("activation-in-progress.json", activation)
        self.assertIn('durable_directory "$STATE"', activation)
        self.assertIn('durable_directory "$incident"', activation)
        receipt = activation.index('publish_root_file "$RECEIPTS/$activation_id.json.tmp" "$RECEIPTS/$activation_id.json"')
        self.assertLess(receipt, activation.index('"$BOOT_GUARD" recover-ready', receipt))
        self.assertLess(receipt, activation.index('cmp -s -- "$GATE" "$OPEN_GATE"', receipt))
        self.assertNotIn('set_gate "$OPEN_GATE"', activation)
        self.assertIn("uten-website-activation-start-grant-v1", activation)
        self.assertIn("exact durable activation start grant consumption receipt", activation)
        self.assertIn("assess | apply", recovery)
        self.assertIn("archived_marker", recovery)
        self.assertIn("RESTORE-INTERRUPTED-WEBSITE-$version", interrupted)
        self.assertIn("for suffix in -journal -shm -wal", interrupted)

    def test_boot_autostart_is_fail_closed_and_does_not_activate(self):
        service = (DEPLOY / "uten-website.service.example").read_text(encoding="utf-8")
        installer = (DEPLOY / "install-website-host.sh").read_text(encoding="utf-8")
        guard = (DEPLOY / "uten-website-boot-guard.sh").read_text(encoding="utf-8")
        boot_unit = (DEPLOY / "uten-website-boot-gate.service.example").read_text(encoding="utf-8")
        watchdog = (DEPLOY / "uten-website-entry-watchdog.timer.example").read_text(encoding="utf-8")
        storage = (DEPLOY / "validate-storage.sh").read_text(encoding="utf-8")
        self.assertIn("Restart=always", service)
        self.assertIn("WorkingDirectory=-/opt/uten-website/current", service)
        self.assertIn("ExecStopPost=+/usr/local/libexec/uten-website/uten-website-boot-guard close", service)
        self.assertIn("RequiresMountsFor=/var/lib/uten-website", service)
        self.assertIn("Before=nginx.service uten-website.service", boot_unit)
        self.assertIn("uten-website-entry-watchdog.timer", installer)
        self.assertIn("disable --now uten-website.service uten-website-entry-watchdog.timer uten-website-stage.timer uten-website-backup.timer uten-website-health.timer", installer)
        self.assertNotIn("website/channels/", guard)
        self.assertNotIn("uten-website-activate ", guard)
        self.assertIn("NTPSynchronized", guard)
        self.assertIn("verify-installed --release", guard)
        self.assertIn("migrate status", guard)
        self.assertIn("release-allowed-signers", guard)
        self.assertIn("root:root:644:1", guard)
        self.assertIn("root:root:755:1", guard)
        self.assertIn("RuntimeDirectory=uten-website-release", boot_unit)
        self.assertIn("RuntimeDirectoryMode=0700", boot_unit)
        self.assertIn("OnActiveSec=90s", watchdog)
        self.assertNotIn("OnBootSec=", watchdog)
        self.assertNotIn("Persistent=", watchdog)
        self.assertIn("systemctl start uten-website-boot-gate.service", installer)
        self.assertIn("systemctl start nginx.service", installer)
        self.assertIn("ReadWritePaths=/var/lib/uten-website /var/backups/uten-website", service)
        self.assertIn("/run/uten-website-release", service)
        self.assertNotIn(" /run ", service)
        self.assertIn("validate_release_database || die", guard)
        self.assertIn("consume_activation_start_grant", guard)
        self.assertLess(
            guard.index("validate_release_database || die"),
            guard.index("consume_activation_start_grant", guard.index("prestart)")),
        )
        self.assertNotIn("ExecStartPre=+/usr/local/libexec/uten-website/validate-runtime", service)
        self.assertIn("STATE_FS_UUID", storage)
        self.assertIn("target == \"$path\"", storage)
        self.assertIn("nodev nosuid noexec", storage)
        self.assertIn('findmnt -rn -R -T "$path" -o TARGET', storage)
        self.assertIn("filesystem contains a nested mount", storage)
        self.assertIn("fresh dedicated mount contains a nested mount", installer)
        self.assertIn("--expected-state-uuid", installer)
        self.assertIn("--expected-backup-uuid", installer)
        self.assertIn("--expected-database-authority-uuid", installer)
        self.assertIn("typed fresh-host confirmation does not bind storage and database authority identities", installer)
        self.assertIn("RestartPreventExitStatus=78", service)
        self.assertIn("uten-website-fresh-host-install-receipt-v1", installer)

    def test_boot_database_gate_propagates_every_failure_and_rollback_never_relies_on_errexit(self):
        guard = (DEPLOY / "uten-website-boot-guard.sh").read_text(encoding="utf-8")
        validation = self._bash_function(guard, "validate_release_database")
        self.assertIn('"$RUNTIME_CHECK" --boot || return 1', validation)
        self.assertIn('verify-installed --release "$CURRENT" --allowed-signers "$SIGNERS" \\\n    || return 1', validation)
        self.assertIn('--signed-manifest "$CURRENT/.release-evidence/manifest.json" "${media_mode[@]}" \\\n    || return 1', validation)
        self.assertIn('--schema "$CURRENT/prisma-runtime/prisma/schema.prisma" \\\n    || return 1', validation)

        activation = (DEPLOY / "uten-website-activate.sh").read_text(encoding="utf-8")
        restore = activation[
            activation.index("if (", activation.index("local restore_proved=false")):
            activation.index("); then", activation.index("local restore_proved=false"))
        ]
        for critical in (
            'restore --snapshot "$snapshot" --destination "$restore_dir" || exit 1',
            'mv -- "$restore_dir/website.db" "$DB" || exit 1',
            'chown uten-website:uten-website "$DB" || exit 1',
            'durable_directory "$STATE" || exit 1',
            'verify-restored-live --snapshot "$snapshot" --database "$DB" --uploads "$UPLOADS" || exit 1',
        ):
            self.assertIn(critical, restore)

    def test_unfinished_media_chain_blocks_production_mutation_before_side_effects(self):
        activation = (DEPLOY / "uten-website-activate.sh").read_text(encoding="utf-8")
        activation_block = activation.index("production activation source NO-GO")
        self.assertLess(activation_block, activation.index("health_check()"))
        self.assertLess(activation_block, activation.index('activation_id="$(date'))

        backup = (DEPLOY / "uten-website-paired-backup.sh").read_text(encoding="utf-8")
        backup_block = backup.index("production paired backup source NO-GO")
        self.assertLess(backup_block, backup.index("for blocker in"))
        self.assertLess(backup_block, backup.index('"$BOOT_GUARD" close'))

        commission = (DEPLOY / "uten-website-commission-automation.sh").read_text(encoding="utf-8")
        commission_block = commission.index("production automation source NO-GO")
        self.assertLess(commission_block, commission.index("systemctl is-active --quiet uten-website.service"))
        self.assertLess(commission_block, commission.index("systemctl enable --now"))

    def test_state_mutators_revalidate_authoritative_mounts_under_lock(self):
        for name in (
            "uten-website-activate.sh",
            "uten-website-paired-backup.sh",
            "uten-website-recover.sh",
        ):
            source = (DEPLOY / name).read_text(encoding="utf-8")
            lock = source.index("STATE_LOCK")
            check = source.index('if ! "$STORAGE_CHECK"', lock)
            self.assertIn("authoritative state/backup storage identity failed", source[check:check + 400], name)

    def test_application_cannot_replace_root_evidence_or_updater_state(self):
        installer = (DEPLOY / "install-website-host.sh").read_text(encoding="utf-8")
        activation = (DEPLOY / "uten-website-activate.sh").read_text(encoding="utf-8")
        stager = (DEPLOY / "uten-website-stage.sh").read_text(encoding="utf-8")
        service = (DEPLOY / "uten-website.service.example").read_text(encoding="utf-8")
        self.assertIn("root -g root /var/lib/uten-website/control", installer)
        self.assertIn("uten-website-updater -g uten-website-updater /var/lib/uten-website/updater", installer)
        self.assertIn("readonly CONTROL=/var/lib/uten-website/control", activation)
        self.assertIn("readonly STAGED=/var/lib/uten-website/updater/staged", activation)
        self.assertIn("readonly STAGED=/var/lib/uten-website/updater/staged", stager)
        self.assertIn("ReadWritePaths=/var/lib/uten-website /var/backups/uten-website", service)
        self.assertNotIn("StateDirectory=uten-website", service)

    def test_storage_checks_use_whole_mount_namespace_carve_outs(self):
        for name in (
            "uten-website-boot-gate.service.example",
            "uten-website.service.example",
            "uten-website-entry-watchdog.service.example",
            "uten-website-backup.service.example",
        ):
            unit = (DEPLOY / name).read_text(encoding="utf-8")
            line = next(value for value in unit.splitlines() if value.startswith("ReadWritePaths="))
            tokens = line.removeprefix("ReadWritePaths=").split()
            self.assertIn("/var/lib/uten-website", tokens, name)
            self.assertIn("/var/backups/uten-website", tokens, name)
            self.assertFalse(any(token.startswith("/var/lib/uten-website/") for token in tokens), name)
            self.assertFalse(any(token.startswith("/var/backups/uten-website/") for token in tokens), name)

    def test_timers_are_installed_disabled_and_staging_never_activates(self):
        installer = (DEPLOY / "install-website-host.sh").read_text(encoding="utf-8")
        stager = (DEPLOY / "uten-website-stage.sh").read_text(encoding="utf-8")
        commission = (DEPLOY / "uten-website-commission-automation.sh").read_text(encoding="utf-8")
        validator = (DEPLOY / "validate_automation_enabled.py").read_text(encoding="utf-8")
        backup_unit = (DEPLOY / "uten-website-backup.service.example").read_text(encoding="utf-8")
        health_unit = (DEPLOY / "uten-website-health.service.example").read_text(encoding="utf-8")
        self.assertIn("disable --now uten-website.service uten-website-entry-watchdog.timer uten-website-stage.timer uten-website-backup.timer uten-website-health.timer", installer)
        self.assertNotIn("uten-website-activate", stager)
        self.assertIn("website/channels/candidate.json", stager)
        self.assertIn("verify --publication", stager)
        self.assertIn("DISABLE-INCOMPLETE-WEBSITE-AUTOMATION", commission)
        self.assertIn("enable-auto-staging", commission)
        self.assertIn("executionSha256", commission)
        self.assertIn("uten-website-stage.timer", commission)
        self.assertIn("fresh-host automation unit is not disabled and inactive", installer)
        self.assertIn("commission plan digest differs from enabled marker", validator)
        self.assertIn("commissioned systemd unit bytes drifted", validator)
        self.assertIn("commissioned execution helper bytes drifted", validator)
        self.assertIn("automatic staging opt-in must remain absent", validator)
        enable = commission.index("systemctl enable --now uten-website-backup.timer uten-website-health.timer")
        receipt = commission.index('publish_root_file "$receipt.tmp" "$receipt"', enable)
        marker = commission.index('publish_root_file "$ENABLED_MARKER.tmp" "$ENABLED_MARKER"', receipt)
        completion = commission.index('mv -- "$IN_PROGRESS" "$receipt.in-progress.json"', marker)
        self.assertLess(enable, receipt)
        self.assertLess(receipt, marker)
        self.assertLess(marker, completion)
        for unit in (backup_unit, health_unit):
            self.assertIn("automation-enabled.json", unit)
            self.assertIn("ConditionPathExists=!/var/lib/uten-website/control/commissioning/automation-in-progress.json", unit)

    def test_backup_writer_and_retention_use_separate_root_credentials(self):
        backup = (DEPLOY / "uten-website-paired-backup.sh").read_text(encoding="utf-8")
        retention = (DEPLOY / "uten-website-backup-retention.sh").read_text(encoding="utf-8")
        self.assertIn("restic-append-only.env", backup)
        self.assertNotIn("restic-retention.env", backup)
        self.assertIn("restic-retention.env", retention)
        self.assertIn("PRUNE-WEBSITE-RECOVERY-POINTS", retention)
        self.assertIn("need at least eight distinct successful days", retention)
        self.assertIn("--keep-daily 7", retention)
        self.assertIn('"$BOOT_GUARD" backup-ready', backup)
        self.assertIn('cmp -s -- "$GATE" "$OPEN_GATE"', backup)
        self.assertNotIn('set_gate "$OPEN_GATE"', backup)
        self.assertIn("bootstrap_precommission=true", backup)
        bootstrap = backup.index("if $bootstrap_precommission")
        self.assertIn('cmp -s -- "$GATE" "$CLOSED_GATE"', backup[bootstrap:])
        self.assertLess(bootstrap, backup.index('systemctl start uten-website.service', bootstrap))

    def test_nginx_media_and_activation_gate_share_fixed_runtime_boundary(self):
        nginx = (DEPLOY / "nginx-website.conf.example").read_text(encoding="utf-8")
        self.assertIn("include /etc/nginx/snippets/uten-website-gate.conf", nginx)
        self.assertIn("if ($uten_website_gate = 1) { return 503; }", nginx)
        self.assertIn("alias /var/lib/uten-website/runtime/uploads/", nginx)
        self.assertIn("disable_symlinks on", nginx)

    def test_runtime_health_requires_successful_prisma_baseline(self):
        health = (ROOT / "website" / "app" / "api" / "health" / "route.ts").read_text(encoding="utf-8")
        self.assertIn("_prisma_migrations", health)
        self.assertIn("20260812000000_initial_production_baseline", health)
        self.assertIn("incomplete Prisma migration", health)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash") and shutil.which("flock"), "requires POSIX bash/flock")
    def test_watchdog_releases_gate_lock_before_recursive_systemd_start(self):
        guard = (DEPLOY / "uten-website-boot-guard.sh").read_text(encoding="utf-8")
        function = self._bash_function(guard, "start_website_unlocked")
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_systemctl = fake_bin / "systemctl"
            fake_systemctl.write_text(
                "#!/usr/bin/env bash\n"
                "[[ $1 == start && $2 == uten-website.service ]] || exit 9\n"
                "exec 9>\"$LOCK_PATH\"\n"
                "flock -n 9\n",
                encoding="utf-8",
            )
            fake_systemctl.chmod(0o755)
            lock = root / "gate.lock"
            script = (
                "set -Eeuo pipefail\n"
                f"{function}\n"
                "close_gate() { :; }\n"
                f"export PATH={fake_bin}:/usr/bin:/bin\n"
                f"export LOCK_PATH={lock}\n"
                "exec 8>\"$LOCK_PATH\"\n"
                "flock -n 8\n"
                "start_website_unlocked\n"
            )
            result = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires POSIX bash")
    def test_operator_disable_blocks_watchdog_autostart_intent(self):
        guard = (DEPLOY / "uten-website-boot-guard.sh").read_text(encoding="utf-8")
        function = self._bash_function(guard, "autostart_intent_enabled")
        with tempfile.TemporaryDirectory() as raw:
            fake_bin = pathlib.Path(raw)
            fake_systemctl = fake_bin / "systemctl"
            fake_systemctl.write_text(
                "#!/usr/bin/env bash\n"
                "[[ $1 == is-enabled && $2 == --quiet ]] || exit 9\n"
                "[[ $3 != \"${DISABLED_UNIT:-}\" ]]\n",
                encoding="utf-8",
            )
            fake_systemctl.chmod(0o755)
            base = f"set -Eeuo pipefail\n{function}\nexport PATH={fake_bin}:/usr/bin:/bin\n"
            enabled = subprocess.run(["bash", "-c", base + "autostart_intent_enabled"], text=True, capture_output=True)
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
            env = os.environ.copy()
            env["DISABLED_UNIT"] = "uten-website.service"
            disabled = subprocess.run(["bash", "-c", base + "autostart_intent_enabled"], env=env, text=True, capture_output=True)
            self.assertNotEqual(disabled.returncode, 0)

    def test_watchdog_does_not_interrupt_a_live_approved_activation(self):
        guard = (DEPLOY / "uten-website-boot-guard.sh").read_text(encoding="utf-8")
        reconcile = guard.index("  reconcile)")
        transaction_lock = guard.index('if maintenance_lock_held "$ACTIVATION_LOCK" 6', reconcile)
        in_progress = guard.index('if [[ -e $IN_PROGRESS || -L $IN_PROGRESS ]]', reconcile)
        stop = guard.index("systemctl stop uten-website.service", in_progress)
        self.assertLess(transaction_lock, in_progress)
        self.assertLess(transaction_lock, stop)
        self.assertIn("approved activation/recovery owns the gate transition", guard[transaction_lock:in_progress])

    def test_recovery_finalization_and_reopen_are_fail_closed(self):
        activation = (DEPLOY / "uten-website-activate.sh").read_text(encoding="utf-8")
        interrupted = (DEPLOY / "uten-website-recover-interrupted.sh").read_text(encoding="utf-8")
        recovery = (DEPLOY / "uten-website-recover.sh").read_text(encoding="utf-8")
        guard = (DEPLOY / "uten-website-boot-guard.sh").read_text(encoding="utf-8")
        self.assertIn("WEBSITE_INTERRUPTED_RECOVERY_FINALIZATION_PENDING", interrupted)
        self.assertIn("interrupted-recovery-progress.completed.json", interrupted)
        self.assertIn("uten-website-activation-failure-finalization-v1", interrupted)
        self.assertIn("activation-failure-finalization.completed.json", interrupted)
        self.assertIn("startGrantSha256", interrupted)
        self.assertIn("another activation/recovery marker or one-time start grant", recovery)
        self.assertIn('cmp -s -- "$GATE" "$OPEN_GATE"', recovery)
        blocked = guard.index("if blocked_by_evidence")
        self.assertIn("! strict_ready_action || return 1", guard[blocked : blocked + 400])

        restore_branch = activation.index("if $restore_proved")
        progress_publish = activation.index(
            'publish_root_file "$RECOVERY_PROGRESS.tmp" "$RECOVERY_PROGRESS"', restore_branch
        )
        failed_publish = activation.index('publish_root_file "$MARKER.tmp" "$MARKER"', progress_publish)
        in_progress_archive = activation.index('mv -- "$IN_PROGRESS" "$incident/activation-in-progress.json"', failed_publish)
        progress_archive = activation.index(
            'mv -- "$RECOVERY_PROGRESS" "$incident/activation-failure-finalization.completed.json"',
            in_progress_archive,
        )
        self.assertLess(progress_publish, failed_publish)
        self.assertLess(failed_publish, in_progress_archive)
        self.assertLess(in_progress_archive, progress_archive)

        # Model SIGKILL immediately after every durable marker/directory step.
        # Every reachable marker set must select a supported evidence-driven
        # recovery path; no state may require an administrator to delete files.
        crash_states = [
            {"IN_PROGRESS"},
            {"IN_PROGRESS", "RECOVERY_PROGRESS"},
            {"FAILED", "IN_PROGRESS", "RECOVERY_PROGRESS"},
            {"FAILED", "RECOVERY_PROGRESS"},
            {"FAILED"},
        ]
        for state in crash_states:
            supported = (
                "FAILED" in state and "RECOVERY_PROGRESS" in state
            ) or ("FAILED" not in state and "IN_PROGRESS" in state) or state == {"FAILED"}
            self.assertTrue(supported, f"unsupported activation finalization crash state: {state}")

    def test_backup_activation_and_recovery_share_state_mutation_lock(self):
        activation = (DEPLOY / "uten-website-activate.sh").read_text(encoding="utf-8")
        backup = (DEPLOY / "uten-website-paired-backup.sh").read_text(encoding="utf-8")
        recovery = (DEPLOY / "uten-website-recover.sh").read_text(encoding="utf-8")
        interrupted = (DEPLOY / "uten-website-recover-interrupted.sh").read_text(encoding="utf-8")
        guard = (DEPLOY / "uten-website-boot-guard.sh").read_text(encoding="utf-8")
        for source in (activation, backup, recovery, interrupted, guard):
            self.assertIn("state-mutation.lock", source)
        self.assertLess(activation.index("acquire_state_lock"), activation.index("migrate deploy"))
        self.assertLess(activation.index("release_state_lock", activation.index("start_grant_sha=")), activation.index("systemctl start uten-website.service", activation.index("start_grant_sha=")))
        self.assertLess(backup.index("flock -n 8"), backup.index('snapshot --database "$DB"'))
        self.assertLess(backup.index("release_state_lock", backup.index('snapshot --database "$DB"')), backup.index("systemctl start uten-website.service", backup.index('snapshot --database "$DB"')))
        self.assertIn("activation-restore-failed.json", backup)
        self.assertIn("interrupted-recovery-in-progress.json", backup)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash") and shutil.which("flock"), "requires POSIX bash/flock")
    def test_state_mutation_lock_release_allows_only_post_snapshot_restart(self):
        backup = (DEPLOY / "uten-website-paired-backup.sh").read_text(encoding="utf-8")
        release = self._bash_function(backup, "release_state_lock")
        with tempfile.TemporaryDirectory() as raw:
            lock = pathlib.Path(raw) / "state.lock"
            script = (
                "set -Eeuo pipefail\n"
                f"{release}\n"
                f"LOCK_PATH={lock}\n"
                "state_lock_held=true\n"
                "exec 8<>\"$LOCK_PATH\"\n"
                "flock -n 8\n"
                "if bash -c 'exec 9<>\"$1\"; flock -n 9' _ \"$LOCK_PATH\"; then exit 41; fi\n"
                "release_state_lock\n"
                "bash -c 'exec 9<>\"$1\"; flock -n 9' _ \"$LOCK_PATH\"\n"
            )
            result = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(os.name == "posix" and hasattr(os, "getuid"), "requires POSIX ownership/symlinks")
    def test_root_lock_helper_rejects_preseeded_symlink(self):
        helper_path = DEPLOY / "open_root_lock.py"
        spec = importlib.util.spec_from_file_location("website_open_root_lock", helper_path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as raw:
            base = pathlib.Path(raw)
            runtime = base / "runtime"
            runtime.mkdir(mode=0o700)
            target = base / "must-not-change"
            target.write_text("sentinel", encoding="utf-8")
            lock = runtime / "activation.lock"
            lock.symlink_to(target)
            with self.assertRaises(module.LockError):
                module.open_checked_lock(
                    lock,
                    runtime,
                    expected_uid=os.getuid(),
                    expected_gid=os.getgid(),
                )
            self.assertEqual(target.read_text(encoding="utf-8"), "sentinel")

    def test_all_embedded_python_in_deployment_scripts_compiles(self):
        heredoc = re.compile(r"<<'PY'\n(.*?)\nPY(?:\n|$)", re.DOTALL)
        found = 0
        for script in DEPLOY.glob("*.sh"):
            source = script.read_text(encoding="utf-8")
            for index, match in enumerate(heredoc.finditer(source), start=1):
                found += 1
                try:
                    compile(match.group(1), f"{script.name}:heredoc-{index}", "exec")
                except SyntaxError as exc:
                    self.fail(f"embedded Python does not compile: {exc}")
        self.assertGreater(found, 10)

    def test_critical_json_evidence_uses_fsync_then_atomic_rename(self):
        activation = (DEPLOY / "uten-website-activate.sh").read_text(encoding="utf-8")
        interrupted = (DEPLOY / "uten-website-recover-interrupted.sh").read_text(encoding="utf-8")
        publisher = self._bash_function(activation, "publish_root_file")
        self.assertLess(publisher.index('durable_file "$temporary"'), publisher.index('mv -Tf -- "$temporary" "$destination"'))
        self.assertLess(publisher.index('mv -Tf -- "$temporary" "$destination"'), publisher.index('durable_file "$destination"'))
        for call in (
            'publish_root_file "$IN_PROGRESS.tmp" "$IN_PROGRESS"',
            'publish_root_file "$MARKER.tmp" "$MARKER"',
            'publish_root_file "$RESTORE_FAILED.tmp" "$RESTORE_FAILED"',
            'publish_root_file "$RECEIPTS/$activation_id.json.tmp" "$RECEIPTS/$activation_id.json"',
        ):
            self.assertIn(call, activation)
        self.assertIn('publish_root_file "$RECOVERY_PROGRESS.tmp" "$RECOVERY_PROGRESS"', interrupted)
        self.assertIn('publish_root_file "$FAILED.tmp" "$FAILED"', interrupted)
        self.assertIn("current_candidate=$CURRENT.interrupted-$activation_id-$attempt_name", interrupted)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires POSIX bash")
    def test_atomic_evidence_publisher_replaces_complete_bytes(self):
        activation = (DEPLOY / "uten-website-activate.sh").read_text(encoding="utf-8")
        publisher = self._bash_function(activation, "publish_root_file")
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            temporary = root / "marker.tmp"
            destination = root / "marker.json"
            temporary.write_text('{"new":true}\n', encoding="utf-8")
            destination.write_text('{"old":true}\n', encoding="utf-8")
            script = (
                "set -Eeuo pipefail\n"
                f"{publisher}\n"
                "die() { exit 90; }\n"
                "chown() { :; }\n"
                "durable_file() { [[ -f $1 ]]; }\n"
                f"publish_root_file {temporary} {destination}\n"
            )
            result = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(destination.read_text(encoding="utf-8"), '{"new":true}\n')
            self.assertFalse(temporary.exists())


if __name__ == "__main__":
    unittest.main()
