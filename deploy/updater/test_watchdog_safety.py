from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "deploy/watchdog/uten-imp-watchdog.sh"
ENTRY = REPO / "deploy/watchdog/uten-imp-entry-watchdog.sh"
APP_UNIT = REPO / "deploy/systemd/uten-imp.service.example"
NGINX_DROPIN = REPO / "deploy/systemd/nginx-uten-imp-override.conf.example"
BACKEND_WATCHDOG_UNIT = REPO / "deploy/systemd/uten-imp-watchdog.service.example"
ENTRY_WATCHDOG_UNIT = REPO / "deploy/systemd/uten-imp-entry-watchdog.service.example"
RECOVERY_INGRESS_GATE = REPO / "deploy/updater/recovery_ingress_gate.py"
STORAGE_OBSERVER_UNIT = REPO / "deploy/systemd/uten-imp-storage-observer.service.example"
STORAGE_OBSERVER = REPO / "deploy/updater/storage_mount_observer.py"
TRANSACTION_MARKERS = (
    "activation-failed.json",
    "activation-in-progress.json",
    "boot-enablement-in-progress.json",
    "recovery-in-progress.json",
    "recovery-ingress-pending.json",
    "recovery-ingress-authorization.json",
    "recovery-ingress-finalizing.json",
    "internal-test-onboarding-adoption.json",
    "internal-test-activation-reauthorization.json",
)


class WatchdogStaticContractTest(unittest.TestCase):
    def test_backend_recovery_is_marker_lock_enablement_and_backoff_gated(self) -> None:
        source = BACKEND.read_text(encoding="utf-8")
        for marker in TRANSACTION_MARKERS:
            self.assertIn(marker, source)
        self.assertIn('exec 8<"${OPERATION_LOCK}"', source)
        self.assertIn('systemctl is-enabled --quiet "${TIMER}"', source)
        self.assertIn('systemctl is-enabled --quiet "${SERVICE}"', source)
        self.assertIn('readonly POSTGRES_META_SERVICE=postgresql.service', source)
        self.assertIn('systemctl is-enabled --quiet "${POSTGRES_META_SERVICE}"', source)
        self.assertIn('systemctl is-enabled --quiet "${POSTGRES_SERVICE}"', source)
        self.assertLess(
            source.index('systemctl is-enabled --quiet "${POSTGRES_META_SERVICE}"'),
            source.index('systemctl is-enabled --quiet "${POSTGRES_SERVICE}"'),
        )
        self.assertIn("required_delay=120", source)
        self.assertIn("required_delay=300", source)
        self.assertIn("required_delay=900", source)
        self.assertIn("required_delay=1800", source)
        self.assertLess(source.index("acquire_operation_gate || exit 1"), source.index('systemctl reset-failed "${SERVICE}"'))
        self.assertLess(source.index('systemctl is-enabled --quiet "${SERVICE}"'), source.index('systemctl reset-failed "${SERVICE}"'))
        self.assertLess(source.index('systemctl reset-failed "${DATA_MOUNT_UNIT}"'), source.index('systemctl reset-failed "${SERVICE}"'))
        self.assertLess(source.index('systemctl reset-failed "${SERVICE}"'), source.index('systemctl restart "${SERVICE}"'))
        self.assertIn('if ! write_recovery_state "${attempts}" "${now}"; then', source)
        self.assertIn("cannot durably reserve the automatic recovery backoff state", source)

    def test_late_mount_host_receipt_is_consumed_before_mount_start(self) -> None:
        source = BACKEND.read_text(encoding="utf-8")
        self.assertLess(
            source.index("if ! prepare_data_mount_observation; then"),
            source.index('systemctl start "${STORAGE_OBSERVER_UNIT}"'),
        )
        self.assertLess(
            source.index('systemctl start "${STORAGE_OBSERVER_UNIT}"'),
            source.index("if ! verify_and_consume_data_mount_observation; then"),
        )
        self.assertLess(
            source.index("if ! verify_and_consume_data_mount_observation; then"),
            source.index('systemctl start "${DATA_MOUNT_UNIT}"'),
        )
        self.assertLess(
            source.index('systemctl start "${DATA_MOUNT_UNIT}"'),
            source.index("if ! verify_mounted_storage; then"),
        )
        self.assertLess(
            source.index("if ! verify_mounted_storage; then"),
            source.index('systemctl start "${POSTGRES_SERVICE}"'),
        )
        observer_source = STORAGE_OBSERVER.read_text(encoding="utf-8")
        observer_unit = STORAGE_OBSERVER_UNIT.read_text(encoding="utf-8")
        for sentinel in (
            'REQUEST_PATH = Path(',
            'RECEIPT_PATH = Path(',
            '"nonce": secrets.token_hex(32)',
            '"bootId": _boot_id()',
            '"helperSha256": _sha256(helper_raw)',
            '"deviceRdev": rdev',
            '"status": "eligible-for-data-mount"',
            'or re.search(',
            'r"(?:resync|recovery|reshape|check|repair)',
        ):
            self.assertIn(sentinel, observer_source)
        self.assertIn("PrivateDevices=true", BACKEND_WATCHDOG_UNIT.read_text(encoding="utf-8"))
        self.assertIn("PrivateDevices=false", observer_unit)
        self.assertIn("DevicePolicy=closed", observer_unit)
        self.assertEqual(observer_unit.count("DeviceAllow="), 0)
        self.assertIn("/sys/dev/block", observer_unit)
        self.assertIn("render_observer_unit(device: str | None = None)", observer_source)

    def test_entry_recovery_never_turns_readiness_down_into_jvm_restart(self) -> None:
        source = ENTRY.read_text(encoding="utf-8")
        self.assertIn("entry_is_healthy()", source)
        self.assertIn("application_is_ready", source[source.index("entry_is_healthy()") :])
        self.assertIn("close_ingress_for_readiness_failure", source)
        self.assertIn('systemctl stop "${NGINX_SERVICE}"', source)
        self.assertIn('--property=ActiveState --value', source)
        self.assertNotIn('systemctl restart "${APPLICATION_SERVICE}"', source)
        self.assertIn('exec 8<"${OPERATION_LOCK}"', source)
        self.assertIn('if ! write_recovery_state "${attempts}" "${now}"; then', source)
        self.assertIn("cannot durably reserve the automatic recovery backoff state", source)

    def test_entry_probe_orders_after_but_never_pulls_nginx(self) -> None:
        unit = ENTRY_WATCHDOG_UNIT.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            [line for line in unit if line.startswith("After=")],
            [
                "After=network-online.target nginx.service "
                "uten-imp-recovery-commit-verifier.service"
            ],
        )
        self.assertEqual(
            [line for line in unit if line.startswith("Wants=")],
            ["Wants=network-online.target"],
        )
        for directive in ("Wants=", "Requires=", "BindsTo=", "Upholds="):
            self.assertFalse(
                any(
                    line.startswith(directive) and "nginx.service" in line
                    for line in unit
                ),
                f"{directive} must not pull intentionally disabled/stopped Nginx",
            )

    def test_systemd_has_bounded_native_backoff_and_fail_closed_ingress_graph(self) -> None:
        app = APP_UNIT.read_text(encoding="utf-8")
        nginx = NGINX_DROPIN.read_text(encoding="utf-8")
        recovery_gate = RECOVERY_INGRESS_GATE.read_text(encoding="utf-8")
        backend_watchdog = BACKEND_WATCHDOG_UNIT.read_text(encoding="utf-8")
        self.assertIn("BindsTo=data.mount postgresql@16-main.service", app)
        self.assertIn("RestartSteps=5", app)
        self.assertIn("RestartMaxDelaySec=60s", app)
        self.assertIn("BindsTo=uten-imp.service", nginx)
        self.assertIn("PartOf=uten-imp.service", nginx)
        self.assertIn("ExecStartPre=/usr/local/libexec/uten-imp/uten-imp-wait-ready", nginx)
        self.assertIn("TimeoutStartSec=90s", backend_watchdog)
        # The application consumes a one-use, transaction-bound authorization
        # while activation/recovery markers exist. Nginx has no such authority:
        # ingress must stay closed until the durable transaction is committed.
        self.assertNotIn("activation-in-progress.json", app)
        self.assertNotIn("recovery-in-progress.json", app)
        for marker in (
            "activation-failed.json",
            "activation-in-progress.json",
            "boot-enablement-in-progress.json",
            "recovery-in-progress.json",
            "internal-test-onboarding-adoption.json",
            "internal-test-activation-reauthorization.json",
        ):
            self.assertIn(marker, nginx)
        # The recovery ingress trio cannot be unconditional test(1) gates:
        # recovery starts Nginx only for a short, lock-bound proof window.  The
        # dedicated gate authenticates that window and otherwise fails closed.
        for marker in (
            "recovery-ingress-pending.json",
            "recovery-ingress-authorization.json",
            "recovery-ingress-finalizing.json",
        ):
            self.assertIn(marker, recovery_gate)


@unittest.skipUnless(os.name == "posix", "watchdog behavior harness requires POSIX bash")
class BackendWatchdogBehaviorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="uten-watchdog-test-"))
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.state = self.temp / "state"
        self.release_state = self.temp / "release-state"
        self.release_state.mkdir()
        self.operation_lock = self.release_state / "operation.lock"
        self.operation_lock.write_bytes(b"")
        self.current_target = self.temp / "release"
        (self.current_target / "server").mkdir(parents=True)
        (self.current_target / "server/uten-imp-server.jar").write_bytes(b"jar")
        (self.temp / "current").symlink_to(self.current_target, target_is_directory=True)
        (self.temp / "mounted").touch()
        (self.temp / "data-unit-active").touch()
        (self.temp / "raid-ready").touch()
        (self.temp / "pg-ready").touch()
        self.log = self.temp / "commands.log"
        self._install_fake_commands()
        source = BACKEND.read_text(encoding="utf-8")
        source = source.replace(
            "export PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            f"export PATH={self.bin}:/usr/bin:/bin",
        )
        source = source.replace(
            "/var/lib/uten-imp-release", str(self.release_state)
        ).replace(
            "/opt/uten-imp/current", str(self.temp / "current")
        ).replace(
            "/usr/bin/pg_isready", str(self.bin / "pg_isready")
        )
        source = source.replace(
            '/usr/bin/python3 -I "${STORAGE_HOST_OBSERVER}" prepare-request',
            f"{self.bin}/storage-host-observer prepare-request",
        ).replace(
            '/usr/bin/python3 -I "${STORAGE_HOST_OBSERVER}" verify-and-consume',
            f"{self.bin}/storage-host-observer verify-and-consume",
        ).replace(
            '/usr/bin/python3 -I "${STORAGE_BOOT_VERIFIER}"',
            str(self.bin / "storage-boot-verifier"),
        )
        self.script = self.temp / "watchdog.sh"
        self.script.write_text(source, encoding="utf-8", newline="\n")
        self.script.chmod(0o700)

    def _fake(self, name: str, body: str) -> None:
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body, encoding="utf-8", newline="\n")
        path.chmod(0o700)

    def _install_fake_commands(self) -> None:
        quoted_log = subprocess.list2cmdline([str(self.log)])
        quoted_temp = subprocess.list2cmdline([str(self.temp)])
        self._fake("logger", f'printf "logger %s\\n" "$*" >> {quoted_log}\n')
        self._fake(
            "curl",
            f'if [[ -e {quoted_temp}/health-up ]]; then printf \'{{"status":"UP"}}\\n\'; exit 0; fi\nexit 22\n',
        )
        self._fake("jq", "cat >/dev/null\nexit 0\n")
        self._fake("flock", "exit 0\n")
        self._fake("stat", "printf 'root:uten-imp-updater:660:1\\n'\n")
        self._fake(
            "mountpoint",
            f'[[ -e {quoted_temp}/mounted ]]\n',
        )
        self._fake(
            "pg_isready",
            f'[[ -e {quoted_temp}/pg-ready ]]\n',
        )
        self._fake("sleep", "exit 0\n")
        self._fake(
            "mv",
            f'''if [[ "$*" == *".recovery-attempts."* && -e {quoted_temp}/fail-recovery-state ]]; then exit 1; fi
exec /usr/bin/mv "$@"
''',
        )
        self._fake(
            "storage-host-observer",
            f'''printf "storage-host-observer %s\n" "$*" >> {quoted_log}
case "$1" in
  prepare-request) touch {quoted_temp}/observation-request ;;
  verify-and-consume)
    [[ -e {quoted_temp}/observation-receipt && ! -e {quoted_temp}/fail-observation-receipt ]]
    rm -f {quoted_temp}/observation-request {quoted_temp}/observation-receipt
    ;;
  *) exit 2 ;;
esac
''',
        )
        self._fake(
            "storage-boot-verifier",
            f'''printf "storage-boot-verifier\n" >> {quoted_log}
[[ ! -e {quoted_temp}/fail-storage-verifier ]]
''',
        )
        self._fake(
            "systemctl",
            f'''printf "systemctl %s\\n" "$*" >> {quoted_log}
unit="${{!#}}"
case "$1" in
  is-enabled)
    [[ ! -e {quoted_temp}/disabled-$unit ]]
    ;;
  is-active)
    if [[ "$unit" == postgresql@16-main.service ]]; then
      [[ -e {quoted_temp}/pg-ready ]]
    elif [[ "$unit" == data.mount ]]; then
      [[ -e {quoted_temp}/data-unit-active ]]
    else
      exit 0
    fi
    ;;
  start)
    if [[ "$unit" == postgresql@16-main.service ]]; then touch {quoted_temp}/pg-ready; fi
    if [[ "$unit" == uten-imp-storage-observer.service ]]; then
      [[ -e {quoted_temp}/raid-ready && -e {quoted_temp}/observation-request ]]
      touch {quoted_temp}/observation-receipt
    fi
    if [[ "$unit" == data.mount ]]; then
      [[ ! -e {quoted_temp}/fail-mount-start ]]
      touch {quoted_temp}/mounted {quoted_temp}/data-unit-active
    fi
    ;;
  reset-failed|restart) exit 0 ;;
  *) exit 2 ;;
esac
''',
        )

    def run_watchdog(self) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "UTEN_WATCHDOG_STATE_DIR": str(self.state),
        }
        return subprocess.run(
            ["/bin/bash", str(self.script)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            timeout=10,
            check=False,
        )

    def reach_threshold(self) -> None:
        for _ in range(4):
            self.assertEqual(self.run_watchdog().returncode, 1)

    def test_threshold_recovery_resets_limit_only_after_safe_gates(self) -> None:
        self.reach_threshold()
        commands = self.log.read_text(encoding="utf-8")
        self.assertIn("systemctl reset-failed uten-imp.service", commands)
        self.assertIn("systemctl restart uten-imp.service", commands)
        self.assertLess(
            commands.index("systemctl is-enabled --quiet uten-imp.service"),
            commands.index("systemctl reset-failed uten-imp.service"),
        )
        # A fifth failure is in the two-minute backoff and cannot create a
        # second restart storm even though the probe runs every 15 seconds.
        before = commands.count("systemctl restart uten-imp.service")
        self.assertEqual(self.run_watchdog().returncode, 1)
        after = self.log.read_text(encoding="utf-8").count(
            "systemctl restart uten-imp.service"
        )
        self.assertEqual(before, after)

    def test_persistent_transaction_marker_blocks_threshold_action(self) -> None:
        for marker in TRANSACTION_MARKERS:
            with self.subTest(marker=marker):
                for _ in range(3):
                    self.assertEqual(self.run_watchdog().returncode, 1)
                marker_path = self.release_state / marker
                marker_path.write_text("{}\n", encoding="utf-8")
                self.assertEqual(self.run_watchdog().returncode, 1)
                commands = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
                self.assertNotIn("systemctl reset-failed uten-imp.service", commands)
                marker_path.unlink()
                (self.state / "failures").unlink(missing_ok=True)
                self.log.unlink(missing_ok=True)

    def test_disabled_postgres_meta_unit_blocks_instance_and_application_recovery(self) -> None:
        (self.temp / "disabled-postgresql.service").touch()
        self.reach_threshold()
        commands = self.log.read_text(encoding="utf-8")
        self.assertIn("systemctl is-enabled --quiet postgresql.service", commands)
        self.assertNotIn("systemctl reset-failed postgresql@16-main.service", commands)
        self.assertNotIn("systemctl start postgresql@16-main.service", commands)
        self.assertNotIn("systemctl reset-failed uten-imp.service", commands)
        self.assertNotIn("systemctl restart uten-imp.service", commands)

    def test_late_mount_and_database_recover_without_rapid_restart(self) -> None:
        (self.temp / "mounted").unlink()
        (self.temp / "data-unit-active").unlink()
        (self.temp / "pg-ready").unlink()
        self.reach_threshold()
        commands = self.log.read_text(encoding="utf-8")
        self.assertIn("storage-host-observer prepare-request", commands)
        self.assertIn("systemctl start uten-imp-storage-observer.service", commands)
        self.assertIn("storage-host-observer verify-and-consume", commands)
        self.assertIn("systemctl reset-failed data.mount", commands)
        self.assertIn("systemctl start data.mount", commands)
        self.assertIn("storage-boot-verifier", commands)
        self.assertIn("systemctl reset-failed postgresql@16-main.service", commands)
        self.assertIn("systemctl start postgresql@16-main.service", commands)
        self.assertIn("systemctl restart uten-imp.service", commands)

    def test_late_mount_observer_failure_never_starts_mount_or_database(self) -> None:
        (self.temp / "mounted").unlink()
        (self.temp / "data-unit-active").unlink()
        (self.temp / "pg-ready").unlink()
        (self.temp / "raid-ready").unlink()
        self.reach_threshold()
        commands = self.log.read_text(encoding="utf-8")
        self.assertIn("storage-host-observer prepare-request", commands)
        self.assertIn("systemctl start uten-imp-storage-observer.service", commands)
        self.assertNotIn("systemctl start data.mount", commands)
        self.assertNotIn("systemctl start postgresql@16-main.service", commands)
        self.assertNotIn("systemctl restart uten-imp.service", commands)

    def test_invalid_or_replayed_observer_receipt_never_starts_mount(self) -> None:
        (self.temp / "mounted").unlink()
        (self.temp / "data-unit-active").unlink()
        (self.temp / "pg-ready").unlink()
        (self.temp / "fail-observation-receipt").touch()
        self.reach_threshold()
        commands = self.log.read_text(encoding="utf-8")
        self.assertIn("systemctl start uten-imp-storage-observer.service", commands)
        self.assertIn("storage-host-observer verify-and-consume", commands)
        self.assertNotIn("systemctl reset-failed data.mount", commands)
        self.assertNotIn("systemctl start data.mount", commands)
        self.assertNotIn("systemctl start postgresql@16-main.service", commands)

    def test_post_mount_verifier_failure_never_starts_database_or_app(self) -> None:
        (self.temp / "mounted").unlink()
        (self.temp / "data-unit-active").unlink()
        (self.temp / "pg-ready").unlink()
        (self.temp / "fail-storage-verifier").touch()
        self.reach_threshold()
        commands = self.log.read_text(encoding="utf-8")
        self.assertIn("systemctl start data.mount", commands)
        self.assertIn("storage-boot-verifier", commands)
        self.assertNotIn("systemctl start postgresql@16-main.service", commands)
        self.assertNotIn("systemctl restart uten-imp.service", commands)

    def test_recovery_state_publish_failure_never_resets_or_starts_units(self) -> None:
        (self.temp / "pg-ready").unlink()
        (self.temp / "fail-recovery-state").touch()
        self.reach_threshold()
        commands = self.log.read_text(encoding="utf-8")
        self.assertNotIn("systemctl reset-failed postgresql@16-main.service", commands)
        self.assertNotIn("systemctl start postgresql@16-main.service", commands)
        self.assertNotIn("systemctl restart uten-imp.service", commands)

    def test_health_proof_clears_backoff_state(self) -> None:
        self.reach_threshold()
        (self.temp / "health-up").touch()
        self.assertEqual(self.run_watchdog().returncode, 0)
        self.assertEqual((self.state / "recovery-attempts").read_text(), "0 0\n")


@unittest.skipUnless(os.name == "posix", "watchdog behavior harness requires POSIX bash")
class EntryWatchdogStateFailureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="uten-entry-watchdog-test-"))
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.state = self.temp / "state"
        self.release_state = self.temp / "release-state"
        self.release_state.mkdir()
        (self.release_state / "operation.lock").write_bytes(b"")
        for name in (
            "timer-enabled",
            "nginx-enabled",
            "application-enabled",
            "nginx-active",
            "application-active",
            "entry-up",
        ):
            (self.temp / name).touch()
        self.log = self.temp / "commands.log"
        self._install_fake_commands()
        source = ENTRY.read_text(encoding="utf-8").replace(
            "export PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            f"export PATH={self.bin}:/usr/bin:/bin",
        ).replace(
            "/var/lib/uten-imp-release", str(self.release_state)
        )
        self.script = self.temp / "entry-watchdog.sh"
        self.script.write_text(source, encoding="utf-8", newline="\n")
        self.script.chmod(0o700)

    def _fake(self, name: str, body: str) -> None:
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body, encoding="utf-8", newline="\n")
        path.chmod(0o700)

    def _install_fake_commands(self) -> None:
        quoted_log = subprocess.list2cmdline([str(self.log)])
        quoted_temp = subprocess.list2cmdline([str(self.temp)])
        self._fake("logger", f'printf "logger %s\\n" "$*" >> {quoted_log}\n')
        self._fake(
            "curl",
            f'''if [[ "$*" == *"/actuator/health/readiness"* ]]; then
  [[ -e {quoted_temp}/readiness-up ]] || exit 22
  printf '{{"status":"UP"}}\\n'
  exit 0
fi
[[ -e {quoted_temp}/nginx-active && -e {quoted_temp}/entry-up ]] || exit 22
printf '<script src="flutter_bootstrap.js"></script>\\n'
''',
        )
        self._fake("jq", "cat >/dev/null\nexit 0\n")
        self._fake(
            "flock",
            f'''if [[ "$*" == *" 8"* && -e {quoted_temp}/operation-lock-held ]]; then exit 1; fi
exit 0
''',
        )
        self._fake("stat", "printf 'root:uten-imp-updater:660:1\\n'\n")
        self._fake(
            "mv",
            f'''if [[ "$*" == *".recovery-attempts."* && -e {quoted_temp}/fail-recovery-state ]]; then exit 1; fi
exec /usr/bin/mv "$@"
''',
        )
        self._fake(
            "systemctl",
            f'''printf "systemctl %s\n" "$*" >> {quoted_log}
case "$1" in
  is-enabled)
    unit="${{@: -1}}"
    case "$unit" in
      uten-imp-entry-watchdog.timer) [[ -e {quoted_temp}/timer-enabled ]] ;;
      nginx.service) [[ -e {quoted_temp}/nginx-enabled ]] ;;
      uten-imp.service) [[ -e {quoted_temp}/application-enabled ]] ;;
      *) exit 1 ;;
    esac
    ;;
  is-active)
    unit="${{@: -1}}"
    case "$unit" in
      nginx.service) [[ -e {quoted_temp}/nginx-active ]] ;;
      uten-imp.service) [[ -e {quoted_temp}/application-active ]] ;;
      *) exit 1 ;;
    esac
    ;;
  show)
    if [[ "$2" == nginx.service && "$*" == *"--property=ActiveState"* ]]; then
      if [[ -e {quoted_temp}/nginx-active ]]; then printf 'active\\n'; else printf 'inactive\\n'; fi
      exit 0
    fi
    exit 2
    ;;
  stop)
    [[ "$2" == nginx.service ]] || exit 2
    rm -f -- {quoted_temp}/nginx-active
    ;;
  start|restart)
    [[ "$2" == nginx.service ]] || exit 2
    touch {quoted_temp}/nginx-active
    ;;
  reset-failed) exit 0 ;;
  *) exit 2 ;;
esac
''',
        )

    def run_watchdog(self) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "UTEN_ENTRY_WATCHDOG_STATE_DIR": str(self.state),
        }
        return subprocess.run(
            ["/bin/bash", str(self.script)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            timeout=10,
            check=False,
        )

    def reach_threshold(self) -> None:
        for _ in range(4):
            self.assertEqual(self.run_watchdog().returncode, 1)

    def commands(self) -> str:
        if not self.log.exists():
            return ""
        return self.log.read_text(encoding="utf-8")

    def test_short_readiness_jitter_does_not_close_ingress(self) -> None:
        for _ in range(3):
            self.assertEqual(self.run_watchdog().returncode, 1)
        self.assertTrue((self.temp / "nginx-active").exists())
        self.assertNotIn("systemctl stop nginx.service", self.commands())

    def test_threshold_readiness_failure_closes_and_proves_ingress_inactive(self) -> None:
        self.reach_threshold()
        self.assertFalse((self.temp / "nginx-active").exists())
        commands = self.commands()
        self.assertIn("systemctl stop nginx.service", commands)
        self.assertIn(
            "systemctl show nginx.service --property=ActiveState --value", commands
        )
        self.assertNotIn("systemctl restart uten-imp.service", commands)
        self.assertNotIn("systemctl start uten-imp.service", commands)

    def test_recovered_readiness_reopens_ingress_with_bounded_start(self) -> None:
        self.reach_threshold()
        (self.temp / "readiness-up").touch()
        self.assertEqual(self.run_watchdog().returncode, 1)
        self.assertTrue((self.temp / "nginx-active").exists())
        commands = self.commands()
        self.assertIn("systemctl reset-failed nginx.service", commands)
        self.assertIn("systemctl start nginx.service", commands)
        self.assertNotIn("systemctl restart uten-imp.service", commands)
        self.assertEqual(self.run_watchdog().returncode, 0)
        self.assertEqual((self.state / "failures").read_text(), "0\n")
        self.assertEqual((self.state / "recovery-attempts").read_text(), "0 0\n")

    def test_marker_and_operation_lock_block_all_service_actions(self) -> None:
        for blocker in (*TRANSACTION_MARKERS, "operation-lock-held"):
            with self.subTest(blocker=blocker):
                path = (
                    self.release_state / blocker
                    if blocker.endswith(".json")
                    else self.temp / blocker
                )
                path.touch()
                self.reach_threshold()
                commands = self.commands()
                self.assertNotIn("systemctl stop nginx.service", commands)
                self.assertNotIn("systemctl start nginx.service", commands)
                self.assertNotIn("systemctl restart nginx.service", commands)
                path.unlink()
                (self.state / "failures").unlink(missing_ok=True)
                self.log.unlink(missing_ok=True)

    def test_disabled_but_active_nginx_is_still_closed_and_never_reopened(self) -> None:
        (self.temp / "nginx-enabled").unlink()
        self.reach_threshold()
        self.assertFalse((self.temp / "nginx-active").exists())
        self.assertIn("systemctl stop nginx.service", self.commands())
        (self.temp / "readiness-up").touch()
        self.assertEqual(self.run_watchdog().returncode, 1)
        self.assertNotIn("systemctl start nginx.service", self.commands())
        self.assertNotIn("systemctl restart nginx.service", self.commands())

    def test_recovery_state_publish_failure_never_resets_or_restarts_nginx(self) -> None:
        (self.temp / "readiness-up").touch()
        (self.temp / "entry-up").unlink()
        (self.temp / "fail-recovery-state").touch()
        self.reach_threshold()
        commands = self.commands()
        self.assertNotIn("systemctl reset-failed nginx.service", commands)
        self.assertNotIn("systemctl restart nginx.service", commands)
        self.assertNotIn("systemctl start nginx.service", commands)


if __name__ == "__main__":
    unittest.main()
