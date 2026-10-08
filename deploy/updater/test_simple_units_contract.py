"""Cross-file contract of the server hardening baseline (2026-10-06, ADR-157).

Pure text checks over the shipped units, host snippets and scripts, so a later edit to one
file cannot silently drift from the others: one 3-day retention for every backup, sandboxed
units that still list every path their program writes, retired backup units gone, and no
secret or live address in the repository copies.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import unittest

from test_simple_release_retention import bash_path

ROOT = Path(__file__).resolve().parents[2]
DEPLOY = ROOT / "deploy"
UNITS = DEPLOY / "simple" / "units"
HOST = DEPLOY / "simple" / "host"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def directives(text: str, key: str) -> list:
    return [line.split("=", 1)[1] for line in text.splitlines() if line.startswith(key + "=")]


def write_paths(unit: str) -> list:
    paths = []
    for value in directives(unit, "ReadWritePaths"):
        paths.extend(item.lstrip("-") for item in value.split())
    return paths


def covered(path: str, grants: list) -> bool:
    return any(path == grant or path.startswith(grant.rstrip("/") + "/") for grant in grants)


class RetentionIsThreeDaysEverywhereTest(unittest.TestCase):
    def test_every_backup_keeps_three_days(self):
        paired = read(DEPLOY / "postgres/backup/paired_internal_backup.py")
        self.assertRegex(paired, r"(?m)^    retention_days: int = 3$")
        example = json.loads(read(DEPLOY / "postgres/backup/paired-internal-backup.example.json"))
        self.assertEqual(3, example["retention_days"])
        updater = read(DEPLOY / "simple/uten-imp-updater.sh")
        self.assertIn('"${UTEN_BACKUP_KEEP_DAYS:=3}"', updater)
        self.assertIn("\nUTEN_BACKUP_KEEP_DAYS=3\n", read(DEPLOY / "simple/updater.env.example"))
        repo2 = read(HOST / "pgbackrest-20-uten-imp-repo2.conf.example")
        self.assertIn("\nrepo2-retention-full=3\n", repo2)
        self.assertIn("\nrepo2-retention-full-type=count\n", repo2)
        self.assertIn("\nrepo1-retention-full=3\n", read(DEPLOY / "setup/phase2-postgres.sh"))

    def test_dual_repo_commissioning_gates_accept_three_restore_points(self):
        # A fresh phase2 host keeps 3 full backups; every legacy health/acceptance gate must accept 3.
        backup = DEPLOY / "postgres/backup"
        self.assertIn("\nMINIMUM_RESTORE_POINTS = 3\n", read(backup / "pgbackrest_repo2.py"))
        self.assertIn("\nMINIMUM_RESTORE_POINTS = 3\n", read(backup / "backup_commissioner.py"))
        self.assertIn("\nMINIMUM_RECOVERY_RESTORE_POINTS = 3\n", read(DEPLOY / "updater/release_updater.py"))
        policy = json.loads(read(backup / "repo2-policy.example.json"))
        self.assertEqual(3, policy["repo2"]["retentionFull"])
        self.assertEqual(3, policy["repo2"]["retentionArchive"])
        self.assertEqual(3, policy["health"]["minimumSuccessfulFullRestorePoints"])
        self.assertIn('"repo1-retention-full=3\\n"', read(backup / "internal_test_first_backup_commissioner.py"))
        for path in (backup / "pgbackrest_repo2.py", backup / "backup_commissioner.py",
                     backup / "backup_acceptance.py", DEPLOY / "updater/release_updater.py"):
            text = read(path)
            self.assertIsNone(re.search(r"(?:count|points|point_count|\)) < 7\b", text), path.name)
            self.assertNotIn("seven restore point", text, path.name)
            self.assertNotIn("seven successful restore", text, path.name)

    def test_status_page_bound_matches_the_paired_timer(self):
        timer = read(UNITS / "uten-paired-internal-backup.timer")
        runs = directives(timer, "OnCalendar")
        self.assertEqual(["*-*-* 03:40:00", "*-*-* 13:10:00"], runs)
        exporter = read(DEPLOY / "monitoring/server_status_export.py")
        self.assertIn(f"PAIRED_RUNS_PER_DAY = {len(runs)}\n", exporter)
        check = read(HOST / "uten-host-check.sh")
        # Longest gap between runs is 13:10 -> 03:40 (14.5 h) plus delay; the stale alarm waits 16 h.
        self.assertIn("-le 57600 ]", check)


class ApplicationUnitTest(unittest.TestCase):
    unit = read(UNITS / "uten-imp.service")

    def test_only_the_attachment_volume_and_logs_are_writable(self):
        self.assertEqual(["/var/lib/uten-imp-media/attachments", "/var/log/uten-imp"], write_paths(self.unit))
        self.assertNotIn("/data/uten-imp/attachments", "\n".join(directives(self.unit, "ReadWritePaths")))
        self.assertIn("ProtectSystem=strict", self.unit)
        self.assertIn("RequiresMountsFor=/var/lib/uten-imp-media/attachments", self.unit)

    def test_hardening_items(self):
        for line in ("UMask=0077", "LimitCORE=0", "CapabilityBoundingSet=", "AmbientCapabilities=",
                     "ProtectProc=invisible", "NoNewPrivileges=true", "RestrictNamespaces=true",
                     "RestrictSUIDSGID=true", "LockPersonality=true", "SystemCallArchitectures=native",
                     "ProtectClock=true", "ProtectHostname=true", "ProtectKernelLogs=true",
                     "MemoryHigh=5G", "MemoryMax=6G", "TasksMax=1024", "LimitNOFILE=65536",
                     "OnFailure=uten-alert@%n.service"):
            self.assertIn("\n" + line + "\n", self.unit, line)
        self.assertIn("clamav-daemon.service", directives(self.unit, "Wants")[0])
        # The JVM JIT needs writable+executable memory; /proc/stat feeds actuator CPU metrics.
        self.assertNotIn("MemoryDenyWriteExecute", self.unit.replace("# 不加 MemoryDenyWriteExecute", ""))
        self.assertNotIn("\nProcSubset=", self.unit)


    def test_task_cap_sits_above_the_status_page_thread_alarms(self):
        # The whole cgroup (JVM threads + soffice) hits TasksMax as "unable to create native thread" and
        # ExitOnOutOfMemoryError restarts the JVM: the status page must turn yellow and red before that.
        probe = read(ROOT / "server/src/main/java/com/uten/imp/features/admin/serverstatus/ServerStatusProbe.java")
        warning = int(re.search(r"threads-warning:(\d+)", probe).group(1))
        critical = int(re.search(r"threads-critical:(\d+)", probe).group(1))
        cap = int(directives(self.unit, "TasksMax")[0])
        self.assertLess(warning, critical)
        self.assertGreater(cap, critical)
        self.assertIn("-XX:+ExitOnOutOfMemoryError", self.unit)


class UpdaterUnitTest(unittest.TestCase):
    unit = read(UNITS / "uten-imp-updater.service")
    script = read(DEPLOY / "simple/uten-imp-updater.sh")
    schedule = read(DEPLOY / "simple/update_schedule.py")

    def test_every_path_the_updater_and_scheduler_write_is_granted(self):
        grants = write_paths(self.unit)
        lock = re.search(r"(?m)^LOCK_FILE=(\S+)$", self.script).group(1)
        backup = re.search(r'"\$\{UTEN_BACKUP_DIR:=([^}]+)\}"', self.script).group(1)
        base = re.search(r'"\$\{UTEN_BASE:=([^}]+)\}"', self.script).group(1)
        state = re.search(r'STATE_DIR = Path\("([^"]+)"\)', self.schedule).group(1)
        status = re.search(r'STATUS_PATH = Path\("([^"]+)"\)', self.schedule).group(1)
        for path in (os.path.dirname(lock), backup, base, state, os.path.dirname(status),
                     os.path.dirname(os.path.dirname(status))):
            self.assertTrue(covered(path, grants), path)
        self.assertNotIn("/run", grants)  # only /run/lock, never the whole of /run
        self.assertIn("ProtectSystem=strict", self.unit)
        # Directories the scheduler creates on first run exist before the sandboxed ExecStart.
        self.assertIn(f"ExecStartPre=+/usr/bin/install -d -o root -g root -m 0700 {state}", self.unit)
        self.assertIn("ExecStartPre=+/usr/bin/install -d -o root -g root -m 0755 /var/lib/uten-imp", self.unit)

    def test_sandbox_items(self):
        for line in ("NoNewPrivileges=true", "PrivateTmp=true", "PrivateDevices=true", "ProtectHome=true",
                     "ProtectKernelTunables=true", "ProtectKernelModules=true", "ProtectKernelLogs=true",
                     "ProtectControlGroups=true", "ProtectClock=true", "ProtectHostname=true",
                     "RestrictSUIDSGID=true", "RestrictRealtime=true", "RestrictNamespaces=true",
                     "LockPersonality=true", "SystemCallArchitectures=native",
                     "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK",
                     "OnFailure=uten-alert@%n.service"):
            self.assertIn("\n" + line + "\n", self.unit, line)


class BackupUnitsTest(unittest.TestCase):
    def test_pgbackup_runs_both_repositories_and_is_sandboxed(self):
        unit = read(UNITS / "uten-pgbackup.service")
        start = directives(unit, "ExecStart")
        self.assertEqual(1, len(start))
        self.assertIn("--repo=1 --type=full backup || rc=1", start[0])
        self.assertIn("--repo=2 --type=full backup || rc=1", start[0])
        self.assertIn("exit $$rc", start[0])  # "$$" is a literal "$" for systemd
        self.assertNotIn("ExecStartPost", unit)  # backup already expires by retention
        self.assertEqual([], directives(unit, "PrivateTmp"))  # /tmp/pgbackrest lock is shared with archive-push
        self.assertIn("User=postgres", unit)
        repo2 = re.search(r"(?m)^repo2-path=(\S+)$", read(HOST / "pgbackrest-20-uten-imp-repo2.conf.example")).group(1)
        grants = write_paths(unit)
        for path in ("/data/backups/pgbackrest", repo2, "/var/log/pgbackrest", "/tmp"):
            self.assertIn(path, grants)
        # Only repo1's disk is a hard dependency: a dead backup volume must not stop the repo1 backup
        # (a failed mount dependency leaves the unit inactive, so OnFailure would never fire either).
        self.assertEqual(["/data/backups/pgbackrest"], directives(unit, "RequiresMountsFor"))
        self.assertIn(f"-{repo2}", directives(unit, "ReadWritePaths")[0].split())
        self.assertNotIn(repo2, directives(unit, "ReadWritePaths")[0].split())
        mount = "srv-uten\\x2dbackup.mount"  # systemd-escape -p --suffix=mount /srv/uten-backup
        self.assertTrue(repo2.startswith("/srv/uten-backup/"), repo2)
        self.assertEqual([mount], directives(unit, "Wants"))
        self.assertIn(mount, directives(unit, "After")[0].split())
        for line in ("NoNewPrivileges=true", "ProtectSystem=strict", "CapabilityBoundingSet=",
                     "OnFailure=uten-alert@%n.service"):
            self.assertIn("\n" + line + "\n", unit, line)
        self.assertEqual(["*-*-* 02:17:00"], directives(read(UNITS / "uten-pgbackup.timer"), "OnCalendar"))

    def test_paired_backup_unit_is_the_single_live_source(self):
        unit = read(UNITS / "uten-paired-internal-backup.service")
        self.assertIn("/usr/local/lib/uten-imp/paired_internal_backup.py --config "
                      "/etc/uten-imp/paired-internal-backup.json", unit)
        self.assertEqual(["/data/uten-imp-backups/paired"], write_paths(unit))
        self.assertIn("OnFailure=uten-alert@%n.service", unit)
        self.assertFalse((DEPLOY / "systemd/uten-paired-internal-backup.service.example").exists())
        self.assertFalse((DEPLOY / "systemd/uten-paired-internal-backup.timer.example").exists())

    def test_retired_backup_chain_is_gone(self):
        for retired in (UNITS / "uten-backup.service", UNITS / "uten-backup.timer",
                        DEPLOY / "simple/uten-backup-daily.sh"):
            self.assertFalse(retired.exists(), retired)


class AlertingAndHostFilesTest(unittest.TestCase):
    files = sorted(path for path in list(UNITS.iterdir()) + list(HOST.iterdir()) if path.is_file())

    def test_every_on_failure_target_ships(self):
        for path in self.files:
            for target in directives(read(path), "OnFailure"):
                self.assertEqual("uten-alert@%n.service", target, path.name)
        self.assertTrue((UNITS / "uten-alert@.service").is_file())

    def test_no_crlf_secret_or_live_address_in_repository_copies(self):
        live_address = re.compile(r"\b(?:192\.168|10|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d{1,3}\.\d{1,3}\b")
        for path in self.files:
            raw = path.read_bytes()
            self.assertNotIn(b"\r\n", raw, path.name)
            text = raw.decode("utf-8")
            self.assertIsNone(live_address.search(text), path.name)
        self.assertIn("REPLACE", read(HOST / "pgbackrest-20-uten-imp-repo2.conf.example").split("repo2-cipher-pass=")[1])
        self.assertFalse((HOST / "alert.curl.example").exists())
        self.assertIn("__ADMIN_TAILSCALE_IP__", read(HOST / "fail2ban-00-uten-ignore.local.example"))

    def test_alerts_are_recorded_locally_without_network_credentials(self):
        alert = read(HOST / "uten-alert.sh")
        self.assertIn("/usr/bin/python3 -I /usr/local/libexec/uten-host-alert.py", alert)
        self.assertNotIn("curl", alert)
        unit = read(UNITS / "uten-alert@.service")
        self.assertIn("IPAddressDeny=any", unit)
        self.assertIn("UTEN_SERVER_STATUS_HOST_ALERT_FILE=/var/lib/uten-alert/events.json",
                      read(UNITS / "uten-imp.service"))

    def test_ssh_snippets_keep_passwords_off(self):
        sshd = read(HOST / "sshd-00-uten-imp.conf.example")
        for line in ("PasswordAuthentication no", "KbdInteractiveAuthentication no", "AuthenticationMethods publickey"):
            self.assertIn("\n" + line + "\n", sshd)
        self.assertIn("\nssh_pwauth: false\n", read(HOST / "cloud-init-99-uten-ssh-pwauth.cfg"))

    @unittest.skipUnless(bash_path(), "bash is required for the syntax check")
    def test_shell_scripts_parse(self):
        for path in HOST.glob("*.sh"):
            result = subprocess.run([bash_path(), "-n", path.as_posix()], capture_output=True, text=True, check=False)
            self.assertEqual(0, result.returncode, f"{path.name}: {result.stderr}")


class OcrSidecarTest(unittest.TestCase):
    def test_sidecar_writes_no_bytecode_hides_proc_and_starts_at_boot(self):
        unit = read(DEPLOY / "ocr/uten-paddle-ocr.service")
        self.assertIn("\nEnvironment=PYTHONDONTWRITEBYTECODE=1\n", unit)
        self.assertIn("\nProtectProc=invisible\n", unit)
        installer = read(DEPLOY / "ocr/install-paddle-ocr.sh")
        self.assertIn("\nsystemctl enable uten-paddle-ocr\n", installer)
        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", installer)
        self.assertIn('[[ "$(id -u)" != 0 ]]', installer)
        self.assertIn("require_root_owned_tree", installer)


if __name__ == "__main__":
    unittest.main()
