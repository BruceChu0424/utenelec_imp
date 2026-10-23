import concurrent.futures
import copy
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
import uuid

import control_plane as cp


class ControlPlaneTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = [1800000000.0]
        self.config = {"allowedOrigins": ["http://127.0.0.1:9087"],
                       "enrollmentBrokerSha256": cp.digest("broker-secret"),
                       "enrollmentEnabledUntil": self.now[0] + 600,
                       "agents": {"backup": {"tokenSha256": cp.digest("backup-secret"),
                                             "targetIds": ["cloud-archive"], "canDrill": False},
                                  "management": {"tokenSha256": cp.digest("worker-secret"),
                                                 "targetIds": ["management-drill"], "canDrill": True}}}
        self.control = cp.ControlPlane(Path(self.temp.name) / "state.sqlite3", self.config, lambda: self.now[0], master_key=b"M" * 32)

    def refused(self, code, fn):
        with self.assertRaises(cp.Refused) as error:
            fn()
        self.assertEqual(code, error.exception.code)

    def enroll(self):
        reply = self.control.issue_enrollment("broker-secret", {"subject": "test-superadmin", "account": "admin",
                                                               "stepUpVerified": True, "localSuperAdmin": True})
        token = reply["enrollmentToken"]
        claim = self.control.claim_enrollment({"token": token})
        self.secret = claim["totpSecret"]
        self.control.finish_enrollment({"token": token, "password": "Independent-test-credential-9271!",
                                        "otp": cp.totp(self.secret, int(self.now[0] // 30))})
        self.now[0] += 30
        reply = self.control.login({"account": "admin", "password": "Independent-test-credential-9271!",
                                    "otp": cp.totp(self.secret, int(self.now[0] // 30))}, "local")
        self.token, self.csrf = reply["accessToken"], reply["csrfToken"]
        self.user = self.control.session(self.token, self.csrf, fresh=True)

    def revision(self):
        return self.control.state(self.user)["revision"]

    def ready(self):
        self.enroll()
        self.control.put_target(self.user, "cloud-archive", {"label": "Cloud archive", "agentId": "backup",
                               "kind": "ARCHIVE", "expectedRevision": self.revision()})
        self.control.put_target(self.user, "management-drill", {"label": "Isolated management worker", "agentId": "management",
                               "kind": "DRILL", "expectedRevision": self.revision()})
        self.point = {"id": "set-1", "storageTargetId": "cloud-archive", "recoverableUntil": cp.utc(self.now[0] - 60),
                      "manifestSha256": "a" * 64, "cipherSha256": "b" * 64,
                      "complete": True, "keysCovered": True, "verified": True}
        self.point["cipherVerified"] = True
        self.snapshot = {"agentId": "backup", "sequence": 1, "observedAt": cp.utc(self.now[0]),
                         "health": "HEALTHY", "recoveryPoints": [self.point]}
        self.control.snapshot("backup-secret", self.snapshot)
        self.control.snapshot("worker-secret", {"agentId": "management", "sequence": 1,
                              "observedAt": cp.utc(self.now[0]), "health": "HEALTHY", "recoveryPoints": []})

    def job(self):
        return {"requestId": str(uuid.uuid4()), "kind": "DRILL", "targetId": "management-drill",
                "recoveryPointId": "set-1", "expectedRevision": self.revision()}

    def test_no_default_admin_and_enrollment_requires_local_step_up_and_short_window(self):
        self.refused("AUTHENTICATION_FAILED", lambda: self.control.login({"account": "admin", "password": "anything"}, "local"))
        self.refused("UNAUTHORIZED", lambda: self.control.issue_enrollment("wrong", {}))
        self.refused("LOCAL_STEP_UP_REQUIRED", lambda: self.control.issue_enrollment("broker-secret", {
            "subject": "user", "account": "user", "localSuperAdmin": False, "stepUpVerified": True}))
        self.now[0] += 601
        self.refused("ENROLLMENT_WINDOW_CLOSED", lambda: self.control.issue_enrollment("broker-secret", {
            "subject": "user", "account": "user", "localSuperAdmin": True, "stepUpVerified": True}))

    def test_enrollment_is_once_only_and_totp_cannot_be_replayed(self):
        issued = self.control.issue_enrollment("broker-secret", {"subject": "user", "account": "user",
                                             "localSuperAdmin": True, "stepUpVerified": True})
        token = issued["enrollmentToken"]
        self.control.claim_enrollment({"token": token})
        self.refused("ENROLLMENT_EXPIRED", lambda: self.control.claim_enrollment({"token": token}))
        self.enroll()
        self.refused("AUTHENTICATION_FAILED", lambda: self.control.login({"account": "admin", "password": "Independent-test-credential-9271!",
                     "otp": cp.totp(self.secret, int(self.now[0] // 30))}, "other"))

    def test_csrf_fresh_mfa_expiry_and_independent_revocation(self):
        self.enroll()
        self.refused("CSRF_REQUIRED", lambda: self.control.session(self.token, "wrong", fresh=True))
        self.now[0] += 301
        self.refused("FRESH_MFA_REQUIRED", lambda: self.control.session(self.token, self.csrf, fresh=True))
        self.control.session(self.token)
        with self.control.transaction() as db:
            db.execute("UPDATE users SET revoked=1")
        self.refused("UNAUTHORIZED", lambda: self.control.session(self.token))

    def test_sqlite_contains_seed_reference_not_recoverable_totp_seed(self):
        self.enroll()
        with self.control.connect() as db:
            reference = db.execute("SELECT totp_secret FROM users").fetchone()[0]
            self.assertTrue(reference.startswith("hmac-sha256-v1:"))
            self.assertNotIn(self.secret, "\n".join(db.iterdump()))
        with self.assertRaisesRegex(ValueError, "master does not match"):
            cp.ControlPlane(self.control.database, self.config, lambda: self.now[0], master_key=b"N" * 32)
        other = cp.ControlPlane(Path(self.temp.name) / "other.sqlite3", self.config, lambda: self.now[0], master_key=b"N" * 32)
        self.assertNotEqual(self.secret, other.totp_key("test-superadmin", reference))
        restarted = cp.ControlPlane(self.control.database, self.config, lambda: self.now[0], master_key=b"M" * 32)
        self.refused("UNAUTHORIZED", lambda: restarted.session(self.token))

    def test_catalog_withdrawal_and_stale_observation_do_not_leave_point_available(self):
        self.ready()
        self.assertTrue(self.control.state(self.user)["recoveryPoints"][0]["available"])
        replacement = {**self.snapshot, "sequence": 2, "recoveryPoints": []}
        self.control.snapshot("backup-secret", replacement)
        self.assertFalse(self.control.state(self.user)["recoveryPoints"][0]["available"])
        self.refused("RECOVERY_POINT_AVAILABILITY_UNCONFIRMED", lambda: self.control.create_job(self.user, self.job()))
        self.control.snapshot("backup-secret", {**self.snapshot, "sequence": 3})
        self.now[0] += 301
        self.assertFalse(self.control.state(self.user)["recoveryPoints"][0]["available"])

    def test_failed_logins_are_persisted_and_rate_limited(self):
        for _ in range(8):
            self.refused("AUTHENTICATION_FAILED", lambda: self.control.login({"account": "unknown", "password": "wrong"}, "peer"))
        self.refused("AUTHENTICATION_RATE_LIMITED", lambda: self.control.login({"account": "unknown", "password": "wrong"}, "peer"))

    def test_agent_cannot_register_target_or_become_admin(self):
        self.refused("UNAUTHORIZED", lambda: self.control.dispatch("PUT", "/v1/targets/cloud-archive", {}, "backup-secret", "", "peer"))
        self.refused("AGENT_UNAUTHORIZED", lambda: self.control.snapshot("backup-secret", {
            "agentId": "management", "sequence": 1, "health": "HEALTHY"}))

    def test_snapshot_replay_scope_freshness_and_manifest_immutability(self):
        self.ready()
        self.refused("SNAPSHOT_REPLAY", lambda: self.control.snapshot("backup-secret", self.snapshot))
        bad = copy.deepcopy(self.snapshot)
        bad["sequence"] = 2
        bad["recoveryPoints"][0]["cipherSha256"] = "c" * 64
        self.refused("RECOVERY_POINT_IMMUTABLE", lambda: self.control.snapshot("backup-secret", bad))
        bad["recoveryPoints"][0]["storageTargetId"] = "unauthorized-target"
        self.refused("TARGET_SCOPE_DENIED", lambda: self.control.snapshot("backup-secret", bad))
        bad["observedAt"] = cp.utc(self.now[0] - 301)
        self.refused("STALE_SNAPSHOT", lambda: self.control.snapshot("backup-secret", bad))

    def test_target_registration_cas_and_archive_cannot_claim_drill(self):
        self.enroll()
        self.refused("STATE_CHANGED", lambda: self.control.put_target(self.user, "cloud-archive", {
            "label": "Cloud", "agentId": "backup", "kind": "ARCHIVE", "expectedRevision": -1}))
        self.refused("DRILL_EXECUTOR_NOT_COMMISSIONED", lambda: self.control.put_target(self.user, "cloud-archive", {
            "label": "Cloud", "agentId": "backup", "kind": "DRILL", "expectedRevision": self.revision()}))

    def test_drill_is_real_queue_lease_and_requires_complete_isolation_evidence(self):
        self.ready()
        body = self.job()
        point = self.control.state(self.user)["recoveryPoints"][0]
        self.assertFalse(point["keysCovered"], "archive publisher cannot attest restored keys")
        self.assertFalse(point["verified"], "archive publisher cannot attest restored business data")
        job = self.control.create_job(self.user, body)
        self.assertEqual("QUEUED", job["state"])
        self.assertEqual(job, self.control.create_job(self.user, body))
        self.refused("DRILL_EXECUTOR_NOT_COMMISSIONED", lambda: self.control.claim("backup-secret", {"agentId": "backup"}))
        claimed = self.control.claim("worker-secret", {"agentId": "management"})
        self.assertEqual(body["requestId"], claimed["job"]["id"])
        self.assertEqual({"job": None}, self.control.claim("worker-secret", {"agentId": "management"}))
        completion = {"leaseToken": claimed["leaseToken"], "success": True, "evidence": {}}
        self.refused("RESTORE_EVIDENCE_INCOMPLETE", lambda: self.control.complete("worker-secret", job["id"], completion))
        completion["evidence"] = {**dict.fromkeys(cp.EVIDENCE, True), "reportSha256": "d" * 64}
        completed = self.control.complete("worker-secret", job["id"], completion)
        self.assertEqual("SUCCEEDED", completed["state"])
        self.assertFalse(self.control.state(self.user)["promotionAllowed"])
        self.refused("LEASE_INVALID", lambda: self.control.complete("worker-secret", job["id"], completion))

    def test_concurrent_admins_cannot_start_two_drills(self):
        self.ready()
        first, second = self.job(), self.job()
        def start(body):
            try:
                return self.control.create_job(self.user, body)["state"]
            except cp.Refused as error:
                return error.code
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(start, (first, second)))
        self.assertEqual(1, results.count("QUEUED"))
        self.assertTrue(any(x in ("STATE_CHANGED", "JOB_ALREADY_ACTIVE") for x in results))

    def test_expired_lease_is_unknown_and_is_never_replayed(self):
        self.ready()
        job = self.control.create_job(self.user, self.job())
        claim = self.control.claim("worker-secret", {"agentId": "management"})
        self.now[0] += 3601
        state = self.control.state(self.user)
        self.assertEqual("UNKNOWN", state["jobs"][0]["state"])
        self.assertEqual({"job": None}, self.control.claim("worker-secret", {"agentId": "management"}))
        self.refused("LEASE_INVALID", lambda: self.control.complete("worker-secret", job["id"], {
            "leaseToken": claim["leaseToken"], "success": True, "evidence": {}}))

    def test_promotion_stays_blocked_even_after_successful_drill_or_claimed_fencing(self):
        self.enroll()
        self.refused("PROMOTION_NOT_COMMISSIONED", lambda:
                     self.control.dispatch("POST", "/v1/promotions", {"fenced": True, "verified": True},
                                           self.token, self.csrf, "local"))

    def test_public_state_has_no_credentials_or_leases(self):
        self.ready()
        self.control.create_job(self.user, self.job())
        claim = self.control.claim("worker-secret", {"agentId": "management"})
        state = json.dumps(self.control.state(self.user))
        for secret in (self.secret, self.token, self.csrf, claim["leaseToken"], "tokenSha256", "password_hash"):
            self.assertNotIn(secret, state)

    def test_configuration_rejects_arbitrary_endpoints_and_commands(self):
        cp.validate_config(self.config)
        for field in ("endpoint", "command", "restorePath"):
            config = copy.deepcopy(self.config)
            config["agents"]["backup"][field] = "http://169.254.169.254/latest/meta-data"
            with self.assertRaises(ValueError):
                cp.validate_config(config)
        config = copy.deepcopy(self.config)
        config["allowedOrigins"] = ["https://*.example.com"]
        with self.assertRaises(ValueError):
            cp.validate_config(config)

    def test_http_public_shell_is_independent_and_browser_origin_is_enforced(self):
        server = cp.ThreadingHTTPServer(("127.0.0.1", 0), cp.Handler)
        server.control = self.control
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
        connection.request("GET", "/")
        response = connection.getresponse()
        self.assertEqual(200, response.status)
        self.assertIn("frame-ancestors 'none'", response.getheader("Content-Security-Policy"))
        self.assertIn("运行与灾备", response.read().decode())
        connection.request("POST", "/v1/auth/login", "{}", {"Content-Type": "application/json", "Origin": "https://evil.example"})
        response = connection.getresponse()
        self.assertEqual(403, response.status)
        self.assertEqual("ORIGIN_DENIED", json.loads(response.read())["code"])
        connection.close()


if __name__ == "__main__":
    unittest.main()
